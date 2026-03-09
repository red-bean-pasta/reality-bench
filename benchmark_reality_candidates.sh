#! /bin/bash

set -eu -o pipefail


Ipv6_Mode=false 
Client_Address=""
Sites=()
Test_File="" Csv_Target_Column="ORIGIN"
Output_Path=""

Winner_Seats=5

PrintHelp(){ cat <<EOF
Usage:
    -h, --help
        Print help
    -4, --ipv4)
        Test in IPv4. This is the default
    -6, --ipv6
        Test in IPv6. Use this if ever intending to connect over IPv6. While SSL certificate doesn't differentiate IPv6 and IPv4, many domains may serve only in IPv4 or have different routing rules for IPv6
    -c, --client-address
        Client address. Will be pinged and compare with the TLS handshake time between Reality server and the camouflage website
    -f, --file
        .txt or .csv file that lists test sites
    -k, --column
        The column name in .csv file that points to test domains. Default to "$Csv_Target_Column" if not provided
    -n, --seats
        How many sites to retain in final ranking. Default to $Winner_Seats
    -o, --output
        Path to save all test results
    SITE
        Test sites separated by space
Example:
    bash $0 -6 -c address.close.to.you -o result.txt -f test.csv -k "domain_column" www.example.com download.example.com
EOF
}


Scores=()
Client_Tcping_Result=""


Main(){
    CheckDependency tcping
    echo

    ProcessArgs "$@"    
    echo

    Log "Tcping client address $Client_Address..."
    Client_Tcping_Result=$(GetTcpingTime "$Client_Address") || exit
    Log "Tcping result (min/avg/max ms): $Client_Tcping_Result"
    echo

    trap PrintWinners EXIT INT TERM HUP

    if [[ ${#Sites[@]} -gt 0 ]]; then
        Log "Benchmarking command-line sites..."
        local s; for s in "${Sites[@]}"; do
            TestSingleSite "$s" || true
            sleep 0.2
            echo
        done
        echo
    fi

    if [[ -n $Test_File ]]; then
        Log "Benchmarking sites defined in $Test_File..."
        TestFileSites "$Test_File" "$Csv_Target_Column"
        echo
    fi
}


CheckDependency(){
    for i in "${@}"; do
        if ! command -v "$i" >/dev/null 2>&1; then
            Log "ERROR: Dependency $i is not installed"
            exit 1
        fi
    done
}


ProcessArgs(){
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                PrintHelp; exit 0 ;;
            -c|--client-address)
                Client_Address=$2; shift 2 ;;
            -f|--file)
                Test_File=$2; shift 2 ;;
            -k|--column)
                Csv_Target_Column=$2; shift 2 ;;
            -n|--seats)
                Winner_Seats=$2; shift 2 ;;
            -6|--ipv6)
                Ipv6_Mode=true; shift ;;
            -4|--ipv4)
                Ipv6_Mode=false; shift ;;
            -o|--output)
                Output_Path=$2; shift 2 ;;
            *)
                Sites+=("$1"); shift ;;
        esac
    done

    if [[ ${#Sites[@]} -eq 0 && ! $Test_File ]]; then
        Log "ERROR: No test site provided"
        exit 1
    fi
    if $Ipv6_Mode; then
        Log "Test is performed in IPv6 mode"
    else
        Log "Test is performed in IPv4 mode"
    fi
    if [[ -z $Client_Address ]]; then
        Log "ERROR: Client address not provided"
        exit 1
    fi
}


TestFileSites(){
    local file=$1 column=$2
    if CheckIfCsv "$file"; then
      input_stream() { ExtractCsv "$file" "$column"; }
    else
      input_stream() { ExtractTxt "$file"; }
    fi

    local s; while IFS= read -r s; do
        TestSingleSite "$s" || true
        sleep 0.2
        echo
    done < <(input_stream)

    unset -f input_stream
}


TestSingleSite(){
    local site=$1
    local mode; $Ipv6_Mode && mode="-6" || mode="-4"
    
    local -A result

    Log "Establishing TLS handshake with $site..."
    local output; if ! output=$(timeout 3s openssl s_client  "$mode"  -connect "$site:443" -alpn h2,http/1.1 -status </dev/null 2>/dev/null | tr -d '\000'); then # </dev/null to immediately terminate ssl after handshake
        Log "Cannot handshake with $site. Aborting..."
        return 1
    fi
    result[tls1_3]=false; printf "%s" "$output" | LogGrep -qIi "TLSv1.3" && result[tls1_3]=true # -i case-insensitive -I ignore binary
    result[h2]=false; printf "%s" "$output" | LogGrep -qIi "ALPN protocol: h2"  && result[h2]=true
    result[x25519]=false; printf "%s" "$output" | LogGrep -qIi "X25519" && result[x25519]=true

    Log "Checking OSCP support for $site..."
    local ocsp_status; ocsp_status=$(printf "%s" "$output" | LogGrep -I "OCSP Response Status")
    result[ocsp]=false; echo "$ocsp_status" | LogGrep -qi "successful" && result[ocsp]=true
    
    Log "Curling the content of $site..."
    local status_codes=() handshake_times=()
    for i in {1..5}; do
        if ! output=$(curl "$mode" --connect-timeout 6 -sS --tlsv1.3 --http2 -I -w "SSL: %{time_appconnect}\n" "https://$site"); then
            Log "Curl $i failed"
            continue
        fi
        status_codes+=("$(printf "%s" "$output" | head -n 1 | awk '{print $2}')")
        handshake_times+=("$(printf "%s" "$output" | tail -n 1 | awk '{print $2 * 1000}')")
        Log "Curl $i finished"
    done
    if FloatCheck "${#status_codes[@]} < 5 * 0.8"; then
        Log "Curl failed too many times. Aborting..."
        return 1
    fi
    result[no_redirect]=true; [[ " ${status_codes[*]} " == *" 3"!(07)* ]] && result[no_redirect]=false
    result[handshake_time]=$(EvaluateMinAvgMax "${handshake_times[@]}")

    Log "Scoring test result..."
    local score; score=$(Score result)
    local info; info=$(PrintSiteResult result)
    if FloatCheck "$score > 0"; then
        AddIfTop "$score" "$site" "$info"
    fi
    printf  "%s\nScore: %s\n%s\n" "$site" "$score" "$info" | { [[ -n "$Output_Path" ]] && tee "$Output_Path" || cat; }
}


Score(){
    local -n _dict=$1

    # Required items
    local score=0
    local required=(tls1_3 h2 x25519 no_redirect)
    local i; for i in "${required[@]}"; do
        if ! ${_dict[$i]}; then
            echo "$score"
            return 0
        fi
    done
    ((score+=50))

    local room=$(( 100 - score ))

    # Boolean items
    local -A bool_weights=(
        [ocsp]=0.5
    )
    local k; local w; for k in "${!bool_weights[@]}"; do
        if ${_dict[$k]}; then
            w=${bool_weights[$k]}
            score=$(FloatCalculate "$score + $room * $w")
        fi
    done

    # Comparable items
    local -A numeric_weights=(
        [latency]=0.5
    )
    w=${numeric_weights[latency]}
    Log "Roughly benchmarking TLS handshake time with tcping lantency..."
    local latency_weight; latency_weight=$(WeighTlsHandshakeLatency "${_dict[handshake_time]}")
    Log "TLS handshake weight: $latency_weight"
    score=$(FloatCalculate "$score + $room * $w * $latency_weight")

    echo "$score"
}


PrintSiteResult(){ local -n _dict=$1; cat <<EOF
    Required:
        TLS 1.3: $(CheckSupport "${_dict[tls1_3]}")
        H2: $(CheckSupport "${_dict[h2]}")
        X25519: $(CheckSupport "${_dict[x25519]}")
        No redirection: $(CheckSupport "${_dict[no_redirect]}")
    Elective:
        OCSP: $(CheckSupport "${_dict[ocsp]}")
        TLS certificate fetch time: ${_dict[handshake_time]} ms
EOF
}


PrintWinners(){
    if [[ ${#Scores[@]} -eq 0 ]]; then
        echo "All candidates failed"
        return
    fi
    echo "Winners:"
    printf "%s\n\n" "${Scores[@]}"
}


GetTcpingTime(){
    Log "Tcping with 6 packets..."
    local output; for i in {1..3}; do
        if ! output=$(tcping -c 6 -t 3 --no-color "$1" 443); then
            Log "Attempt $i: Failed to tcping $1"
            continue
        fi

        local unsuccessful_probes; unsuccessful_probes=$(printf "%s" "$output" | awk -F' ' '/unsuccessful probes/ {print $3}')
        if FloatCheck "$unsuccessful_probes > 6 * 0.2"; then
            Log "Attempt $i: Too many unsuccessful probes: $unsuccessful_probes"
            continue
        fi
        
        local result; result=$(printf "%s" "$output" | awk -F' ' '/rtt/ {print $3}')
        echo "$result"
        return 0
    done
    
    Log "Failed to tcping $1"
    return 1
}


WeighTlsHandshakeLatency(){
    local -a tls_result; IFS='/' read -ra tls_result <<<"$1"
    local -a tcp_result; IFS='/' read -ra tcp_result <<<"$Client_Tcping_Result"

    local tls_avg=${tls_result[1]} tcp_avg=${tcp_result[1]}
    local tls_span; tls_span=$(FloatCalculate "${tls_result[2]} - ${tls_result[0]}")
    local tcp_span; tcp_span=$(FloatCalculate "${tcp_result[2]} - ${tcp_result[0]}")

    # TLS handshake takes 2RTT or 6 directional trips, one for TCP and one for TLS; meanwhile, tcping only takes only 1
    local visibility; visibility=$(FloatCalculate "$tls_avg / 2 / ($tcp_avg + $tcp_span + 0.25 * $tls_span / 2 + 10)") # 10ms acts as the tcp_jitter floor since the tcp_jitter samples is too small
    FloatCalculate "1 / (1 + (2 * $visibility)^3)"
}


CheckIfCsv(){
    local l; l="$(grep -m1 -v '^[[:space:]]*$' "$1" || true)"
    [[ "$l" == *","* ]]
}


ExtractCsv(){
    awk -v column="$2" -F',' '
        /^[[:space:]]*$/ { next }
        header==0 {
            header==1
            for (i=1; i<=NF; i++) {
                if ($i == column) { 
                    idx=i; break 
                }
            }
            if (!idx) { 
                print "ERROR: column not found: " column > "/dev/stderr"
                exit 2 
            }
            next
        }
        {
            v = $idx
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            if (v != "") print v
        }
    ' "$1"
}


ExtractTxt(){
    awk '
        { gsub(/\r$/, "") }
        { sub(/^[[:space:]]+/, "") }
        { sub(/[[:space:]]+$/, "") }
        $0 != "" { print }
    ' "$1"
}


CheckSupport(){
    $1 && echo "Supported" || echo "Failed"
}


AddIfTop(){
    local score=$1; local domain=$2; local info=$3
    local value="$domain"$'\n'"Score: $score"$'\n'"$info"

    local current_taker current_score
    local i; for ((i=0; i<Winner_Seats; i++)); do
        current_taker=${Scores[$i]:-}
        if [[ -z $current_taker ]]; then
            Scores[i]="$value"
            break
        fi
        
        current_score=${current_taker#*$'\n'Score: }; 
        current_score=${current_score%%$'\n'*}
        if FloatCheck "$score <= $current_score"; then
            continue
        fi

        local j; local front; for ((j=Winner_Seats-1; j>i; j--)); do
            front=${Scores[j-1]:-}
            [[ -n $front ]] && Scores[j]=${Scores[j-1]:-}
        done
        Scores[i]="$value"
        break
    done
}


Log(){
    printf "%s\n" "$@" >&2
}


LogGrep(){
    grep "$@" >&2
}


FloatCheck(){
    awk "BEGIN { exit !($1) }"
}


FloatCalculate(){
    awk "BEGIN { printf \"%.${2:-2}f\", $1 }"
}


SaturateTransform(){
    FloatCalculate "$2 / ($2 + $1)"
}


EvaluateMinAvgMax(){
    printf "%s\n" "${@}" | awk '
        NR == 1 { min = max = $1 }
        {
            if ($1 > max) max = $1
            if ($1 < min) min = $1
            sum += $1
        }
        END {
            if (NR > 0) 
                printf "%d/%.2f/%d", min, sum/NR, max
        }'
}


Main "$@"