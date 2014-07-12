#/bin/bash
set -e

COMMON_ARGS="--privileged -e CATTLE_SCRIPT_DEBUG=${CATTLE_SCRIPT_DEBUG}"
SERVICE=$ARGS
STAMPEDE_PORT=${STAMPEDE_PORT:-8080}
STAMPEDE_VERSION=${STAMPEDE_VERSION:-dev}
CATTLE_VERSION=${CATTLE_VERSION:-dev}

DOCKER_ARGS=
IMAGE=
PIDFILE=
HOST_MNTS=

if [ -n "$CATTLE_SCRIPT_DEBUG" ] || echo "${@}" | grep -q -- --debug; then
    export CATTLE_SCRIPT_DEBUG=true
    export PS4='[${BASH_SOURCE##*/}:${LINENO}] '
    set -x
fi

info()
{
    echo "INFO : $@"
}

pull()
{
    if docker inspect $1 >/dev/null 2>&1; then
        return 0
    fi

    info "Pulling $1"
    docker pull $1
    info "Done pulling $1"
}

notify()
{
    TEXT=$1
    PROP=$2
    CHECK_VALUE=$3

    if [ "$NOTIFY_SOCKET" = "" ]; then
        return 0
    fi

    while true; do
        echo "$TEXT" | ncat -u -U $NOTIFY_SOCKET
        if [ "$(systemctl show -p $PROP $SERVICE)" = "${PROP}=${CHECK_VALUE}" ]; then
            break
        else
            sleep 1
        fi
    done
}

ready()
{
    if [ -n "$MAINPID" ]; then
        if [ ! -e /proc/$MAINPID ]; then
            mainpid $$
        fi
    fi

    if [ "$NOTIFY" != "true" ]; then
        notify "READY=1" SubState running
    fi
}

mainpid()
{
    notify "MAINPID=$1" MainPID $1
    MAINPID=$1
}

setup_ips()
{
    if [ -e /etc/environment ]; then
        source /etc/environment
    fi

    PUBLIC_IP=$COREOS_PUBLIC_IPV4
    PRIVATE_IP=$COREOS_PRIVATE_IPV4

    if [ -n "${STAMPEDE_PRIVATE_IP}" ]; then
        PRIVATE_IP=${STAMPEDE_PRIVATE_IP}
    fi

    if [ -n "${STAMPEDE_PUBLIC_IP}" ]; then
        PUBLIC_IP=${STAMPEDE_PUBLIC_IP}
    fi

    if [ -z "$PRIVATE_IP" ]; then
        PRIVATE_IP="$(ip route get 8.8.8.8 | grep via | awk '{print $7}')"
    fi

    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=${PRIVATE_IP}
    fi
}

getpid()
{
    if [ -e $PIDFILE ]; then
        cat $PIDFILE
    fi
}

run_foreground()
{
    docker run "$@" | bash &
    for i in {1..10}; do
        PID=$(getpid)
        if [ -n "$PID" ]; then
            break
        fi
        sleep 1
    done

    if [ -z "$PID" ]; then
        exit 1
    fi
}

run_background()
{
    ID=$(/usr/bin/docker run -d "$@")
    PID=$(docker inspect -f '{{.State.Pid}}' $ID)
    FROM="/sys/fs/cgroup/systemd/$(grep 'name=systemd' /proc/$$/cgroup | cut -f3 -d:)/cgroup.procs"

    if [ -e "$FROM" ]; then
        echo $PID > $FROM
    fi

    docker logs -f $ID &
}

run()
{
    if docker inspect $NAME >/dev/null 2>&1; then
        docker rm -f $NAME
    fi

    if [ -z "$PIDFILE" ]; then
        run_background "$@"
    else
        run_foreground "$@"
    fi

    mainpid $PID
    ready
}

setup_hostmnts()
{
    for MNT in $HOST_MNTS; do
        if [ ! -e $MNT ]; then
            mkdir -p $MNT
        fi
        COMMON_ARGS="${COMMON_ARGS} -v ${MNT}:/host${MNT}"
    done
}

setup_args()
{
    TAG=${STAMPEDE_VERSION}
    NAME=$(echo $1 | cut -f1 -d.)

    case $NAME in
    cattle-stampede-agent)
        HOST_MNTS="/lib/modules /proc /run /var/lib/docker /var/lib/cattle /opt/bin"
        DOCKER_ARGS="-e CATTLE_EXEC_AGENT=true -e CATTLE_ETCD_REGISTRATION=true -e CATTLE_AGENT_IP=${PUBLIC_IP} -e CATTLE_LIBVIRT_REQUIRED=true"
        ;;
    cattle-libvirt)
        TAG=${CATTLE_VERSION}
        HOST_MNTS="/lib/modules /proc /run /var/lib/docker"
        PIDFILE=/run/cattle/libvirt/libvirtd.pid
        ;;
    cattle-stampede-server)
        NOTIFY=true
        DOCKER_ARGS="-i -v /var/lib/cattle:/var/lib/cattle -e PORT=${STAMPEDE_PORT} -p ${STAMPEDE_PORT}:8080 -e PRIVATE_MACHINE_IP=${PRIVATE_IP} -e PUBLIC_MACHINE_IP=${PUBLIC_IP}"
        ;;
    cattle-stampede)
        HOST_MNTS="/proc"
        DOCKER_ARGS="-e PORT=${STAMPEDE_PORT}"
        ;;
    *)
        echo "Invalid unit name $1"
        exit 1
        ;;
    esac

    IMAGE="$(echo $NAME | sed 's!cattle-!cattle/!'):${TAG}"
}

setup_notify()
{
    if [[ "$NOTIFY" == "true" && -n "$NOTIFY_SOCKET" && -e "$NOTIFY_SOCKET" ]]; then
        COMMON_ARGS="${COMMON_ARGS} -v ${NOTIFY_SOCKET}:${NOTIFY_SOCKET} -e NOTIFY_SOCKET=${NOTIFY_SOCKET}"
    fi
}

setup_ips
setup_args $SERVICE
setup_notify
setup_hostmnts

pull cattle/agent-instance:latest
pull $IMAGE

run $COMMON_ARGS --name $NAME $DOCKER_ARGS $IMAGE
