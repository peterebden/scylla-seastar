#!/bin/bash
# !
# !  Usage: posix_net_conf.sh [iface name, eth0 by default] [-mq|-sq] [-h|--help]
# !
# !  Ban NIC IRQs from being moved by irqbalance.
# !
# !  -sq - set all IRQs of a given NIC to CPU0 and configure RPS
# !  to spreads NAPIs' handling between other CPUs.
# !
# !  -mq - distribute NIC's IRQs among all CPUs instead of binding
# !  them all to CPU0 and do not enable RPS.
# !
# !  If neither -mq nor -sq is given script will use a default mode:
# !     - If number of NIC's IRQs is greater than half of CPUs cores (not including hyperthreads) - use an '-mq' mode.
# !     - Otherwise if number or NIC's IRQs is greater than 7 - use an '-mq' mode.
# !     - Otherwise use an '-sq' mode.
# !
# !  Enable XPS, increase the default values of somaxconn and tcp_max_syn_backlog.
# !
# !  -h|--help - print this help information
# !

#
#  set_one_mask <config file> <CPU mask>
#
set_one_mask()
{
    local cpuset_conf_file=$1
    local mask=`echo $2 | sed -e 's/0x//g'`
    echo "Setting mask $mask in $cpuset_conf_file"
    echo $mask > $cpuset_conf_file
}

#
# Bind RPS queues to CPUs other than CPU0 and its hyper-threading siblings
#
# Use hwloc-distrib for generating the appropriate CPU masks.
#
setup_rps()
{
    local iface=$1
    # If we are in a single core environment - there is no point in configuring RPS
    [[ `hwloc-calc core:0.pu:all` -eq `hwloc-calc all` ]] && return

    local rps_queues_count=`ls -1 /sys/class/net/$iface/queues/*/rps_cpus | wc -l`
    local mask
    local i=0

    # Distribute all cores except for CPU0 siblings
    for mask in `hwloc-distrib --restrict $(hwloc-calc all ~core:0) $rps_queues_count`
    do
        set_one_mask "/sys/class/net/$iface/queues/rx-$i/rps_cpus" $mask
        i=$(( i + 1 ))
    done
}

#
# Spread all XPS queues to over the full cpuset. Don't bother to exclude CPU0
# (and friends) - scylla will just not send from it if its cpuset is properly set.
#
setup_xps()
{
    local iface=$1
    local xps_queues_count=`ls -1 /sys/class/net/$iface/queues/*/xps_cpus | wc -l`
    local mask
    local i=0

    for mask in `hwloc-distrib $xps_queues_count`
    do
        set_one_mask "/sys/class/net/$iface/queues/tx-$i/xps_cpus" $mask
        i=$(( i + 1 ))
    done
}

#
# Prints IRQ numbers for the given physical interface
#
get_irqs()
{
    local iface=$1

    if [[ `ls -1 /sys/class/net/$iface/device/msi_irqs/ | wc -l` -gt 0 ]]; then
        # Device uses MSI IRQs
        ls -1 /sys/class/net/$iface/device/msi_irqs/
    else
        # Device uses INT#x
        cat /sys/class/net/$iface/device/irq
    fi
}

distribute_irqs()
{
    local iface=$1
    local irqs=( `get_irqs $iface` )
    local mask
    local i=0

    for mask in `hwloc-distrib ${#irqs[*]}`
    do
        set_one_mask "/proc/irq/${irqs[$i]}/smp_affinity" $mask
        i=$(( i + 1 ))
    done
}

restart_irqbalance()
{
    local iface=$1
    local config_file="/etc/default/irqbalance"
    local options_key="OPTIONS"
    local systemd=""

    # return early if irqbalance is not running
    ! ps -elf | grep irqbalance | grep -v grep &>/dev/null && return

    if ! test -f $config_file; then
        if test -f /etc/sysconfig/irqbalance; then
            config_file="/etc/sysconfig/irqbalance"
            options_key="IRQBALANCE_ARGS"
            systemd="yes"
        else
            echo "Unknown system configuration - not restarting irqbalance!"
            echo "You have to prevent it from moving $iface IRQs manually!"
            return
        fi
    fi

    local orig_file="$config_file.scylla.orig"

    # Save the original file
    ! test -f $orig_file && cp $config_file $orig_file

    # Remove options parameter if exists
    local tmp_file=`mktemp`
    egrep -v -w ^"\s*$options_key" $config_file > $tmp_file
    mv $tmp_file $config_file

    echo -n "Restarting irqbalance: going to ban the following IRQ numbers: "

    local new_options="$options_key=\""
    local irq
    for irq in `get_irqs $iface`
    do
        new_options="$new_options --banirq=$irq"
        echo -n "$irq "
    done

    echo "..."
    echo "Original irqbalance configuration is in $orig_file"

    new_options="$new_options\""
    echo $new_options >> $config_file

    if [[ -z "$systemd" ]]; then
        /etc/init.d/irqbalance restart
    else
        systemctl try-restart irqbalance
    fi
}

usage()
{
    cat $0 | grep ^"# !" | cut -d"!" -f2-
}

parse_args()
{
    if [[ $# -gt 2 ]]; then
        usage
        exit 1
    fi

    for arg in $@
    do
        case "$arg" in
            "-mq")
                MQ_MODE="mq"
                ;;
            "-sq")
                MQ_MODE="sq"
                ;;
            "-h"|"--help")
                usage
                exit 0
                ;;
            *)
                IFACE=$arg
                ;;
            esac
    done
}

#
# Prints the default MQ mode for a given networking interface
#
get_def_mq_mode()
{
    local iface=$1
    local num_irqs=`get_irqs $iface | wc -l`
    local num_cores=`hwloc-calc --number-of core machine:0`

    if [ "$num_irqs" -ge "$((num_cores / 2))" ] || [ "$num_irqs" -ge 8 ]; then
        echo "mq"
    else
        echo "sq"
    fi
}

IFACE="eth0"
MQ_MODE=""

parse_args $@

[[ -z $MQ_MODE ]] && MQ_MODE=`get_def_mq_mode $IFACE`

# Ban irqbalance from moving NICs IRQs
restart_irqbalance $IFACE

# bind all NIC IRQs to CPU0
if [[ "$MQ_MODE" == "sq" ]]; then
    for irq in `get_irqs $IFACE`
    do
        echo "Binding IRQ $irq to CPU0"
        echo 1 > /proc/irq/$irq/smp_affinity
    done

    # Setup RPS
    setup_rps $IFACE
else # "$MQ_MODE == "mq"
    distribute_irqs $IFACE
fi

# Setup XPS
setup_xps $IFACE

# Increase the socket listen() backlog
echo 4096 > /proc/sys/net/core/somaxconn

# Increase the maximum number of remembered connection requests, which are still
# did not receive an acknowledgment from connecting client.
echo 4096 > /proc/sys/net/ipv4/tcp_max_syn_backlog
