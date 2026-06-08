#!/usr/bin/env bash
# server-stats.sh - Analyse basic server performance stats on any Linux server.
# Usage: chmod +x server-stats.sh && ./server-stats.sh

set -u

# ---------- helpers ----------
print_header() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

# Pretty-print bytes (KB input from /proc/meminfo or `df`)
human_kb() {
    awk -v kb="$1" 'BEGIN{
        split("KB MB GB TB PB", u);
        i=1;
        while (kb>=1024 && i<5){ kb/=1024; i++ }
        printf "%.2f %s", kb, u[i];
    }'
}

# ---------- system info ----------
print_header "SYSTEM INFORMATION"
echo "Hostname     : $(hostname)"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "OS           : ${PRETTY_NAME:-$NAME $VERSION}"
fi
echo "Kernel       : $(uname -r)"
echo "Architecture : $(uname -m)"
echo "Date         : $(date)"
echo "Uptime       :$(uptime -p | sed 's/^up//')"
echo "Load Average :$(uptime | awk -F'load average:' '{print $2}')"

# ---------- CPU usage ----------
print_header "CPU USAGE"
# Sample /proc/stat twice for an accurate snapshot
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat

idle1=$((i1 + w1))
idle2=$((i2 + w2))
non_idle1=$((u1 + n1 + s1 + irq1 + sirq1 + st1))
non_idle2=$((u2 + n2 + s2 + irq2 + sirq2 + st2))
total1=$((idle1 + non_idle1))
total2=$((idle2 + non_idle2))

totald=$((total2 - total1))
idled=$((idle2 - idle1))
if [ "$totald" -gt 0 ]; then
    cpu_usage=$(awk -v t="$totald" -v i="$idled" 'BEGIN{printf "%.2f", (t-i)*100/t}')
else
    cpu_usage="0.00"
fi
echo "CPU cores    : $(nproc)"
echo "CPU usage    : ${cpu_usage}%  (idle: $(awk -v t="$totald" -v i="$idled" 'BEGIN{printf "%.2f", i*100/t}')%)"

# ---------- Memory usage ----------
print_header "MEMORY USAGE"
mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used=$((mem_total - mem_avail))
mem_used_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.2f", u*100/t}')
mem_free_pct=$(awk -v f="$mem_avail" -v t="$mem_total" 'BEGIN{printf "%.2f", f*100/t}')

printf "Total : %s\n" "$(human_kb "$mem_total")"
printf "Used  : %s (%s%%)\n" "$(human_kb "$mem_used")" "$mem_used_pct"
printf "Free  : %s (%s%%)\n" "$(human_kb "$mem_avail")" "$mem_free_pct"

# Swap
swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
if [ "${swap_total:-0}" -gt 0 ]; then
    swap_used=$((swap_total - swap_free))
    swap_used_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.2f", u*100/t}')
    printf "Swap  : %s used / %s total (%s%%)\n" \
        "$(human_kb "$swap_used")" "$(human_kb "$swap_total")" "$swap_used_pct"
fi

# ---------- Disk usage ----------
print_header "DISK USAGE (local filesystems)"
# Aggregate across local filesystems
df -PT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | \
awk '
    function hr(x,    i,arr){
        split("K M G T P", arr);
        i=1; while (x>=1024 && i<5){ x/=1024; i++ }
        return sprintf("%.1f%s", x, arr[i]);
    }
    NR==1{
        printf "%-20s %-8s %10s %10s %10s %6s  %s\n","Filesystem","Type","Size","Used","Avail","Use%","Mount";
        next;
    }
    {
        printf "%-20s %-8s %10s %10s %10s %6s  %s\n",$1,$2,hr($3),hr($4),hr($5),$6,$7;
        ts+=$3; tu+=$4; ta+=$5;
    }
    END{
        if (ts>0){
            printf "\nTotal : %s | Used: %s (%.2f%%) | Free: %s (%.2f%%)\n", \
                hr(ts), hr(tu), tu*100/ts, hr(ta), ta*100/ts;
        }
    }'

# ---------- Top processes by CPU ----------
print_header "TOP 5 PROCESSES BY CPU"
ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu | head -n 6 | \
    awk 'NR==1{printf "%-8s %-12s %-25s %8s %8s\n", $1,$2,$3,$4,$5; next}
         {printf "%-8s %-12s %-25s %8s %8s\n", $1,$2,$3,$4,$5}'

# ---------- Top processes by Memory ----------
print_header "TOP 5 PROCESSES BY MEMORY"
ps -eo pid,user,comm,%cpu,%mem --sort=-%mem | head -n 6 | \
    awk 'NR==1{printf "%-8s %-12s %-25s %8s %8s\n", $1,$2,$3,$4,$5; next}
         {printf "%-8s %-12s %-25s %8s %8s\n", $1,$2,$3,$4,$5}'

# ---------- Stretch: users & logins ----------
print_header "USERS & LOGIN ACTIVITY"
echo "Logged-in users ($(who | wc -l)):"
who || true

if command -v lastb >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
        fails=$(lastb -w 2>/dev/null | grep -vc '^$\|^btmp')
        echo
        echo "Failed login attempts (from lastb): ${fails}"
        echo "Last 5 failed logins:"
        lastb -w 2>/dev/null | head -n 5
    else
        echo
        echo "Failed login attempts: (run as root to read /var/log/btmp via lastb)"
    fi
fi

# ---------- Stretch: network listeners count ----------
if command -v ss >/dev/null 2>&1; then
    print_header "NETWORK"
    echo "TCP listening sockets : $(ss -tln 2>/dev/null | tail -n +2 | wc -l)"
    echo "UDP listening sockets : $(ss -uln 2>/dev/null | tail -n +2 | wc -l)"
    echo "Established connections: $(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)"
fi

echo
echo "Done."
