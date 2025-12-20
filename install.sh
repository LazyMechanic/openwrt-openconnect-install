#!/bin/sh

# Exit on error and undefined variables
set -eu

VERBOSE=0
VPNC_SCRIPT_PATH="/lib/netifd/vpnc-script"
VPN_IF_NAME=""

#===============================================================================
# Color Setup (TTY-aware)
#===============================================================================
if [ -t 1 ]; then
    COLOR_RED="$(printf '\033[0;31m')"
    COLOR_YELLOW="$(printf '\033[0;33m')"
    COLOR_GREEN="$(printf '\033[0;32m')"
    COLOR_BLUE="$(printf '\033[0;34m')"
    COLOR_RESET="$(printf '\033[0m')"
else
    COLOR_RED=''
    COLOR_YELLOW=''
    COLOR_GREEN=''
    COLOR_BLUE=''
    COLOR_RESET=''
fi

#===============================================================================
# Logging Functions
#===============================================================================
log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERRO]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

log_debug() {
    [ "$VERBOSE" -gt 0 ] || return 0
    printf '%s[DEBG]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_debug2() {
    [ "$VERBOSE" -gt 1 ] || return 0
    printf '%s[DEBG]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_debug3() {
    [ "$VERBOSE" -gt 2 ] || return 0
    printf '%s[DEBG]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

#===============================================================================
# Cleanup & Signal Handling
#===============================================================================

cleanup() {
    rc=$?

    # Disable the traps immediately to prevent recursion
    trap - EXIT INT TERM

    log_debug "Running cleanup (exit code: ${rc})"

    if [ "${rc}" -ne 0 ]; then
        log_error "Script exited with error (code ${rc})"
    fi

    exit "${rc}"
}

# Run cleanup on exit and common termination signals
trap cleanup EXIT INT TERM

#===============================================================================
# Helper Functions
#===============================================================================

# Prompts user with a yes/no question and returns 0 for yes, 1 for no
# Parameters:
#   $1 - question
#   $2 - optional default: Y/N (empty = no default)
# Usage:
#   if prompt_yes_no "Do you want to continue?" Y; then
#     echo "User answered yes"
#   else
#     echo "User answered no"
#   fi
prompt_yes_no() {
    prompt="${1}"
    default="${2}"
    answer=""

    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    while true; do
        # Build prompt
        if [ -n "${default}" ]; then
            if [ "${default}" = "Y" ] || [ "${default}" = "y" ]; then
                prompt_next="> [Y/n] "
            else
                prompt_next="> [y/N] "
            fi
        else
            prompt_next="> [y/n] "
        fi

        # Prompt user
        printf "%s" "${prompt_next}"
        read -r answer || return 1 # Ctrl+D counts as no

        # Use default if input is empty
        if [ -z "${answer}" ] && [ -n "${default}" ]; then
            answer="${default}"
        fi

        # Check answer
        case "${answer}" in
        y | Y | yes | YES | Yes)
            return 0
            ;;
        n | N | no | NO | No)
            return 1
            ;;
        *)
            log_error "Please answer yes or no"
            ;;
        esac
    done
}


# Prompts the user with a question and a list of variants.
# If a default is provided and the user presses Enter, the default is returned.
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt text
#   $3 - Default value (empty = no default)
#   $4..$N - Variants. Consist of pairs ('<variant>:[<mapped value>]' '<description>')
#
# Usage:
#   prompt_select \
#       VAR1
#       'Question?' 'ABC' \
#       '1' 'Variant 1' '' \
#       '2' 'Variant 2' '' \
#       'ABC:CBD' 'Variant ABC')"
#
#   case "${VAR1}" in
#       '1') echo "1 selected" ;;
#       '2') echo "2 selected" ;;
#       'CBD') echo "ABC selected" ;;
#   esac
#
#   prompt_select \
#       VAR2
#       'noitseuQ?' '' \
#       '1' 'Variant 1' '' \
#       '2' 'Variant 2' '' \
#       'ABC' 'Variant ABC')"
#
#   case "${VAR2}" in
#       '1') echo "1 selected" ;;
#       '2') echo "2 selected" ;;
#       'ABC') echo "ABC selected" ;;
#   esac
#
# Display:
#   Question?
#     [1] Variant 1
#     [2] Variant 2
#     [ABC] Variant ABC
#   > [ABC]
#   
#   noitseuQ?
#     [1] Variant 1
#     [2] Variant 2
#     [ABC] Variant ABC
#   > 
prompt_select() {
    destvar="${1}"
    prompt="${2}"
    default="${3}"
    shift 3

    validate_destvar "${destvar}"

    # Newline character for string splitting
    nl='
'

    # Build variants list and print menu
    # Each entry stored as "input:mapped" separated by newlines
    variants=""

    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"

    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    while [ $# -ge 2 ]; do
        varspec="$1"
        vardesc="$2"
        shift 2

        # Parse variant:mapped format
        case "${varspec}" in
            *:*)
                varinput="${varspec%%:*}"
                varmapped="${varspec#*:}"
                ;;
            *)
                varinput="${varspec}"
                varmapped="${varspec}"
                ;;
        esac

        log_debug3 "variant: ${varinput} -> ${varmapped} (${vardesc})"

        # Store for later validation
        if [ -z "${variants}" ]; then
            variants="${varinput}:${varmapped}"
        else
            variants="${variants}${nl}${varinput}:${varmapped}"
        fi

        # Print menu item
        printf '  %s) %s\n' "${varinput}" "${vardesc}"
    done

    ans=""

    while :; do
        if [ -n "${default}" ]; then
            printf '> [%s] ' "${default}"
        else
            printf '> '
        fi

        read -r ans || return 1

        # Empty input → use default
        if [ -z "${ans}" ]; then
            if [ -n "${default}" ]; then
                ans="${default}"
            else
                log_error "Input required"
                continue
            fi
        fi

        # Validate and find mapped value
        mapped=""
        found=0
        remaining="${variants}"

        while [ -n "${remaining}" ]; do
            # Extract line and update remaining
            case "${remaining}" in
                *"${nl}"*)
                    line="${remaining%%${nl}*}"
                    remaining="${remaining#*${nl}}"
                    ;;
                *)
                    line="${remaining}"
                    remaining=""
                    ;;
            esac

            [ -z "${line}" ] && continue

            # Parse input:mapped
            entryinput="${line%%:*}"
            entrymapped="${line#*:}"

            if [ "${ans}" = "${entryinput}" ]; then
                mapped="${entrymapped}"
                found=1
                break
            fi
        done

        if [ "${found}" = "1" ]; then
            log_debug3 "input: ${mapped}"
            eval "${destvar}=\${mapped}"
            return 0
        fi

        log_error "Invalid answer, try again."
    done
}

# Prompts the user for private (non-echoed) input, e.g. a password.
# Returns the entered value via stdout.
# If a default is provided and the user presses Enter, the default is returned.
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt text
#   $3 - Optional default value (empty = no default)
#
# Usage:
#   prompt_hidden_input password 'Enter password'
#   [ "${password}" = "..." ] || exit 1
#
#   prompt_hidden_input secret 'Enter secret' 'changeme'
#   [ "${secret}" = "changeme" ] || exit 1
#
# Display:
#   Enter password
#   > 
#   Enter secret
#   > [changeme] 
prompt_hidden_input() {
    destvar="${1}"
    prompt="${2}"
    default="${3:-}"
    inputval=""

    validate_destvar "${destvar}"
    
    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"

    # Print the prompt
    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    # Print the input line with optional default
    if [ -n "${default}" ]; then
        printf '> [%s] ' "${default}"
    else
        printf '> '
    fi

    # shellcheck disable=SC3045
    if read -s -r inputval 2>/dev/null; then
        : # Success, inputval already set
    else
        # Read the input
        # Disable echo via /bin/sh escape sequence
        if [ -t 0 ]; then
            printf '\033[8m'  # ANSI: invisible text
        fi

        read -r inputval

        # Enable echo via /bin/sh escape sequence
        if [ -t 0 ]; then
            printf '\033[28m' # ANSI: visible text
        fi
    fi


    # Print newline since echo was disabled during input
    printf '\n'

    # Use default if input is empty and default is provided
    if [ -z "${inputval}" ] && [ -n "${default}" ]; then
        inputval="${default}"
    fi

    log_debug3 "input: ${inputval}"

    # Set the destination variable
    eval "${destvar}=\${inputval}"
}

# Prompt user for input with optional validation
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt message (required)
#   $3 - Default value (optional)
#   $4 - Validation type (optional, default: any)
#   $5.. - Validation arguments (optional, type-specific)
#
# Usage:
#   prompt_input VAR "prompt" [default] [type] [args]
#
# Validation types:
#   any     - Accept any input (default)
#   number  - Positive integer only (0, 1, 42, ...)
#   string  - Non-empty string, $5 = max length (optional)
#   enum    - Enumeration, $5..$N variants 
#   ipv4    - Valid IPv4 address (0-255 per octet)
#   port    - Valid port number (1-65535)
#   range   - Integer in range $5..=$6
#
# Usage:
#   prompt_input NAME     "Enter name:"
#   prompt_input TAG      "Enter tag:"   "default"
#   prompt_input COUNT    "Enter count:" "10"          "number")
#   prompt_input USERNAME "Username:"    ""            "string" "32")
#   prompt_input IP       "Server IP:"   "192.168.1.1" "ipv4")
#   prompt_input PORT     "Port:"        "8080"        "port")
#   prompt_input PERCENT  "Percent:"     "50"          "range"  "0"   "100")
#   prompt_input TEMP     "Temperature:" "20"          "range"  "-40" "50")
prompt_input() {
    destvar="${1}"
    prompt="${2}"
    shift 2
    
    default=""
    if [ $# -gt 0 ]; then 
        default="${1}"
        shift
    fi

    vtype="any"
    if [ $# -gt 0 ]; then 
        vtype="${1}"
        shift
    fi
    
    vargs="$*"

    validate_destvar "${destvar}"

    ans=""
    err=""

    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"
    log_debug3 "vtype:   ${vtype}"
    log_debug3 "vargs:   ${vargs}"
    
    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"
    
    while :; do
        if [ -n "${default}" ]; then
            printf '> [%s] ' "${default}"
        else
            printf '> '
        fi
        
        read -r ans || return 1
        
        # Use default if empty
        [ -z "${ans}" ] && ans="${default}"
        
        # Still empty and validation required?
        if [ -z "${ans}" ] && [ "${vtype}" != "any" ]; then
            log_error "Input required"
            continue
        fi
        
        # Validate
        err=""
        case "${vtype}" in
            any)
                ;;
            number)
                validate_number "${ans}" ${vargs} || err="Enter a valid number"
                ;;
            string)
                validate_string "${ans}" ${vargs} || err="Invalid string"
                ;;
            enum)
                validate_enum "${ans}" ${vargs} || err="Must be one of: $(prettify_list "${vargs}" inline)"
                ;;
            ipv4)
                validate_ipv4 "${ans}" ${vargs} || err="Invalid IPv4 (e.g., 192.168.1.1)"
                ;;
            port)
                validate_port "${ans}" ${vargs} || err="Port must be 1-65535"
                ;;
            range)
                validate_range "${ans}" ${vargs} || err="Must be between ${1}-${2}"
                ;;
            *)
                log_error "Unknown type '${vtype}'"
                return 2
                ;;
        esac
        
        if [ -n "${err}" ]; then
            log_error "${err}"
            continue
        fi

        log_debug3 "input: ${ans}"

        # Set the destination variable and exit loop
        eval "${destvar}=\${ans}"
        break
    done
}

# Validate variable name to prevent command injection
validate_destvar() {
    destvar="${1}"
    case "${destvar}" in
        ''|*[!a-zA-Z0-9_]*|[0-9]*)
            log_error "Invalid variable name: ${destvar}"
            exit 1
            ;;
    esac
}

validate_number() {
    [ $# -ne 1 ] && {
        log_error "'number' takes no additional arguments (got $(($# - 1)))"
        return 2
    }
    
    case "${1}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

validate_string() {
    [ $# -lt 1 ] && {
        log_error "'string' requires value"
        return 2
    }
    [ $# -gt 3 ] && {
        log_error "'string' takes at most 2 arguments (got $(($# - 1)))"
        return 2
    }

    val="${1}"
    minlen="${2:-}"
    maxlen="${3:-}"

    len="${#val}"

    # Validate min length
    if [ -n "${minlen}" ]; then
        case "${minlen}" in
            ''|*[!0-9]*) log_error "'string' min length must be a number"; return 2 ;;
        esac
        [ "${len}" -lt "${minlen}" ] && return 1
    fi

    # Validate max length
    if [ -n "${maxlen}" ]; then
        case "${maxlen}" in
            ''|*[!0-9]*) log_error "'string' max length must be a number"; return 2 ;;
        esac
        [ "${len}" -gt "${maxlen}" ] && return 1
    fi

    return 0
}

validate_enum() {
    [ $# -lt 2 ] && {
        log_error "'enum' requires at least one allowed value"
        return 2
    }

    val="${1}"
    shift

    for opt do
        [ "${val}" = "${opt}" ] && return 0
    done

    return 1
}

validate_ipv4() {
    [ $# -ne 1 ] && {
        log_error "'ipv4' takes no additional arguments (got $(($# - 1))"
        return 2
    }
    
    case "${1}" in
        *[!0-9.]*) return 1 ;;
        .*|*.|*..*) return 1 ;;
    esac
    
    oifs="${IFS}"
    IFS='.'
    set -- ${1}
    IFS="${oifs}"
    
    [ $# -eq 4 ] || return 1
    
    for octet do
        case "${octet}" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "${octet}" -gt 255 ] && return 1
    done
    
    return 0
}

validate_port() {
    [ $# -ne 1 ] && {
        log_error "'port' takes no additional arguments (got $(($# - 1)))"
        return 2
    }
    
    case "${1}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${1}" -ge 1 ] && [ "${1}" -le 65535 ]
}

validate_range() {
    [ $# -lt 3 ] && {
        log_error "'range' requires min and max arguments"
        return 2
    }
    [ $# -gt 3 ] && {
        log_error "'range' takes exactly 2 arguments (got $(($# - 1)))"
        return 2
    }
    
    val="${1}"
    min="${2}"
    max="${3}"
    
    case "${val#-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    
    [ "${val}" -ge "${min}" ] && [ "${val}" -le "${max}" ]
}

# Returns a formatted string from a space-separated list
# Parameters:
#   $1 - space-separated list
#   $2 - optional mode: "numbered", "inline", default = plain list with '-'
# Usage:
#   result=$(prettify_list "$packages" inline)
prettify_list() {
    list="$1"
    mode="${2:-}"

    result=""

    case "$mode" in
    numbered)
        i=1
        for item in $list; do
            result="${result}${i}. ${item}\n"
            i=$((i + 1))
        done
        ;;
    inline)
        result="["
        sep=""
        for item in $list; do
            result="${result}${sep}${item}"
            sep=", "
        done
        result="${result}]"
        ;;
    *)
        for item in $list; do
            result="${result}- ${item}\n"
        done
        ;;
    esac

    # Return string via stdout
    printf "%b" "$result"
}

#===============================================================================
# Main Logic
#===============================================================================

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -v, --verbose   Enable verbose output
  -h, --help      Show this help message
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -v | --verbose)
            VERBOSE=$((VERBOSE + 1))
            ;;
        -vv)
            VERBOSE=$((VERBOSE + 2))
            ;;
        -vvv)
            VERBOSE=$((VERBOSE + 3))
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        esac
        shift
    done
}

check_dependencies() {
    for cmd in opkg uci; do
        log_debug "Checking dependency: '${cmd}'"
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "Missing dependency: '${cmd}'"
            exit 1
        fi
    done
}

install_openconnect() {
    if ! prompt_yes_no 'Install OpenConnect VPN client package?' Y; then return; fi

    pkg=""
    prompt_select pkg \
        'Select OpenConnect package' '1' \
        '1:luci-proto-openconnect' 'luci-proto-openconnect (with LuCI support)' \
        '2:openconnect' 'openconnect (just VPN client)'

    if ! prompt_yes_no 'Ready to install package?' Y; then return; fi

    log_info "Refreshing packages list..."
    opkg update
    log_info "Installing ${pkg}..."
    opkg install "${pkg}"

    log_info "OpenConnect package installed!"
}

parse_url() {
    # 1. Map arguments to temporary variables
    var_schema="$1"
    var_host="$2"
    var_port="$3"
    var_key="$4"
    input="$5"

    # 2. Initialize output values
    val_schema=""
    val_host=""
    val_port=""
    val_key=""

    # 3. Extract Secret Key (Query string after ?)
    # We use *\?* to match literal '?'
    case "$input" in
        *\?*)
            val_key="${input#*\?}"     # Get part after ?
            input="${input%%\?*}"      # Remove part after ? from input
            ;;
    esac

    # 4. Extract Schema (Prefix before ://)
    case "$input" in
        *://*)
            val_schema="${input%%://*}" # Get part before ://
            input="${input#*://}"       # Remove part before :// from input
            ;;
    esac

    # 5. Cleanup trailing slash (e.g. domain.org/)
    input="${input%/}"

    # 6. Extract Port (Suffix after last :)
    case "$input" in
        *:*)
            val_port="${input##*:}"     # Get part after last :
            val_host="${input%:*}"      # Get part before last :
            ;;
        *)
            val_host="${input}"
            ;;
    esac

    # 7. Apply Default Ports Logic
    # Only if port is empty and schema is known
    if [ -z "${val_port}" ]; then
        case "${val_schema}" in
            http)  val_port="80" ;;
            https) val_port="443" ;;
        esac
    fi

    eval "${var_schema}='${val_schema}'"
    eval "${var_host}='${val_host}'"
    eval "${var_port}='${val_port}'"
    eval "${var_key}='${val_key}'"
}

configure_interface() {
    if ! prompt_yes_no 'Configure VPN interface?' Y; then return; fi

    vpn_if_name=""
    vpn_if_metric=""
    vpn_if_auto=""
    vpn_if_default_route=""
    vpn_if_proto="openconnect"
    vpn_proto=""
    server_uri=""
    server_port=""
    server_hash=""
    username=""
    password=""

    prompt_input vpn_if_name 'Interface name' oc0
    prompt_input vpn_if_metric 'Interface metric' 0 range 0 4294967295
    prompt_input vpn_if_auto 'Bring up on boot' 1 enum 0 1
    prompt_input vpn_if_default_route 'Enable default route' 1 enum 0 1
    prompt_select vpn_proto 'Select protocol' 1 \
        '1:anyconnect' 'Cisco AnyConnect' \
        '2:nc' 'Juniper Network Connect' \
        '3:gp' 'Palo Alto Networks GlobalProtect' \
        '4:pulse' 'Pulse Connect Secure'
    prompt_input server_uri 'Server host' '' string 1

    server_uri_port=""
    parse_url server_uri_schema host server_uri_port server_uri_secret_key "${server_uri}"

    prompt_input server_port 'Server port' "${server_uri_port}" port
    prompt_input server_hash 'Server hash (sha256:XXX)'

    if prompt_yes_no 'Configure user?' Y; then
        prompt_input username 'Username' '' string 1
        prompt_hidden_input password 'Password'
    fi

    VPN_IF_NAME="${vpn_if_name}"

    log_info "Interface name:     [${vpn_if_name}]"
    log_info "Interface metric:   [${vpn_if_metric}]"
    log_info "Interface protocol: [${vpn_if_proto}]"
    log_info "Bring up on boot:   [${vpn_if_auto}]"
    log_info "Default route:      [${vpn_if_default_route}]"
    log_info "VPN Protocol:       [${vpn_proto}]"
    log_info "Server URI:         [${server_uri}]"
    log_info "Server port:        [${server_port}]"
    log_info "Server hash:        [${server_hash}]"
    log_info "Username:           [${username}]"
    log_info "Password:           [${password:+***}]"

    if ! prompt_yes_no 'Ready to create VPN interface?' Y; then return; fi

    if uci -q show "network.${vpn_if_name}" >/dev/null; then
        log_warn "Network '${vpn_if_name}' already exists"
        if ! prompt_yes_no 'Override config?' Y; then return; fi
        uci delete "network.${vpn_if_name}"
    fi

    uci set "network.${vpn_if_name}=interface"
    uci set "network.${vpn_if_name}.name=${vpn_if_name}"
    uci set "network.${vpn_if_name}.metric=${vpn_if_metric}"
    uci set "network.${vpn_if_name}.defaultroute=${vpn_if_default_route}"
    uci set "network.${vpn_if_name}.proto=${vpn_if_proto}"
    uci set "network.${vpn_if_name}.vpn_protocol=${vpn_proto}"
    uci set "network.${vpn_if_name}.uri=${server_uri}"
    uci set "network.${vpn_if_name}.port=${server_port}"
    uci set "network.${vpn_if_name}.serverhash=${server_hash}"
    uci set "network.${vpn_if_name}.username=${username}"
    uci set "network.${vpn_if_name}.password=${password}"

    uci commit network

    log_info "Network interface configured!"
}

configure_firewall() {
    if ! prompt_yes_no 'Configure firewall?' Y; then return; fi

    fw_zone_name=""
    fw_zone_network="${VPN_IF_NAME}"
    fw_zone_masq="1"
    fw_zone_mtu_fix="1"
    fw_zone_input="REJECT"
    fw_zone_output="ACCEPT"
    fw_zone_forward="REJECT"

    prompt_input fw_zone_name 'Firewall zone name' oc string 1
    [ -z "${fw_zone_network}" ] && prompt_input fw_zone_network 'Firewall zone network' '' string 1

    log_info "Zone name:    [${fw_zone_name}]"
    log_info "Network:      [${fw_zone_network}]"
    log_info "Masquarad:    [${fw_zone_masq}]"
    log_info "MSS clamping: [${fw_zone_mtu_fix}]"
    log_info "Input:        [${fw_zone_input}]"
    log_info "Output:       [${fw_zone_output}]"
    log_info "Forward:      [${fw_zone_forward}]"

    if ! prompt_yes_no 'Ready to configure firewall?' Y; then return; fi

    uci add firewall zone
    uci set firewall.@zone[-1]=zone
    uci set "firewall.@zone[-1].name=${fw_zone_name}"
    uci set "firewall.@zone[-1].network=${fw_zone_network}"
    uci set "firewall.@zone[-1].masq=${fw_zone_masq}"
    uci set "firewall.@zone[-1].mtu_fix=${fw_zone_mtu_fix}"
    uci set "firewall.@zone[-1].input=${fw_zone_input}"
    uci set "firewall.@zone[-1].output=${fw_zone_output}"
    uci set "firewall.@zone[-1].forward=${fw_zone_forward}"

    uci add firewall forwarding
    uci set firewall.@forwarding[-1]=forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set "firewall.@forwarding[-1].dest=${fw_zone_name}"

    uci commit firewall

    log_info "Firewall configured!"
}

install_hooks() {
    if ! prompt_yes_no "Install 'vpnc-script' hooks (if 'defaultroute'='1' is set, a routing loop will occur without hooks)?" Y; then return; fi

    # Check vpnc-script installed
    if [ ! -f "${VPNC_SCRIPT_PATH}" ]; then
        log_error "'${VPNC_SCRIPT_PATH}' not found. Skip installation. See 'https://www.infradead.org/openconnect/vpnc-script.html' for more info"
        return 1
    fi

    install_on_connect_script_hook
    install_on_post_disconnect_hook
    install_on_reconnect_hook
    
    log_info "'vpnc-script' hooks installed!"
}

install_on_connect_script_hook() {
    dir="/etc/openconnect/connect.d"
    file="${dir}/10-vpngateway-route-bypass"

    log_debug "Installing '${file}'"

    mkdir -p ${dir}
    cat > "${file}" << 'EOF'
#!/bin/sh
#
# OpenConnect post-connect hook - Add VPN gateway route via WAN
#

. /lib/functions/network.sh
network_flush_cache

STATE_FILE="/tmp/openconnect-route.state"

log() {
    logger -t "openconnect[connect]" "$1"
}

if [ -z "$VPNGATEWAY" ]; then
    log "Error: VPNGATEWAY not set"
    return 1
fi

# Get WAN interface info
network_find_wan WAN_IFACE
[ -z "$WAN_IFACE" ] && WAN_IFACE="wan"

network_get_gateway WAN_GW "$WAN_IFACE"
network_get_device WAN_DEV "$WAN_IFACE"

if [ -z "$WAN_GW" ] || [ -z "$WAN_DEV" ]; then
    log "Error: Could not determine WAN gateway or device"
    return 1
fi

log "Adding route: $VPNGATEWAY via $WAN_GW dev $WAN_DEV"

ip route replace "$VPNGATEWAY" via "$WAN_GW" dev "$WAN_DEV" metric 1

if [ $? -eq 0 ]; then
    log "Successfully added route for $VPNGATEWAY"
    echo "$VPNGATEWAY $WAN_GW $WAN_DEV" > "$STATE_FILE"
    return 0
else
    log "Failed to add route for $VPNGATEWAY"
    return 1
fi
EOF
    
    log_info "Hook '${file}' installed!"
}

install_on_post_disconnect_hook() {
    dir="/etc/openconnect/post-disconnect.d"
    file="${dir}/10-vpngateway-route-revert"

    log_debug "Installing '${file}'"

    mkdir -p ${dir}
    cat > "${file}" << 'EOF'
#!/bin/sh
#
# OpenConnect post-disconnect hook - Remove VPN gateway route
#

STATE_FILE="/tmp/openconnect-route.state"
network_flush_cache

log() {
    logger -t "openconnect[post-disconnect]" "$1"
}

# Try state file first
if [ -f "$STATE_FILE" ]; then
    read -r SAVED_GW SAVED_WAN_GW SAVED_WAN_DEV < "$STATE_FILE"
    
    if [ -n "$SAVED_GW" ]; then
        log "Removing route: $SAVED_GW via $SAVED_WAN_GW dev $SAVED_WAN_DEV"
        ip route del "$SAVED_GW" via "$SAVED_WAN_GW" dev "$SAVED_WAN_DEV" 2>/dev/null
    fi
    
    rm -f "$STATE_FILE"
    log "Route removed and state cleaned up"
    return 0
fi

# Fallback: use VPNGATEWAY if available
if [ -n "$VPNGATEWAY" ]; then
    log "Removing route for $VPNGATEWAY (no state file)"
    ip route del "$VPNGATEWAY" 2>/dev/null
    return 0
fi

log "Warning: No state file and VPNGATEWAY not set"
return 0
EOF
    log_info "Hook '${file}' installed!"
}

install_on_reconnect_hook() {
    dir="/etc/openconnect/reconnect.d"
    file="${dir}/10-vpngateway-route-reload"

    log_debug "Installing '${file}'"

    mkdir -p ${dir}
    cat > "${file}" << 'EOF'
#!/bin/sh
#
# OpenConnect reconnect hook - Remove old route, add new route
#

. /lib/functions/network.sh
network_flush_cache

STATE_FILE="/tmp/openconnect-route.state"

log() {
    logger -t "openconnect[reconnect]" "$1"
}

# --- Remove old route ---

if [ -f "$STATE_FILE" ]; then
    read -r OLD_GW OLD_WAN_GW OLD_WAN_DEV < "$STATE_FILE"
    
    if [ -n "$OLD_GW" ]; then
        log "Removing old route: $OLD_GW via $OLD_WAN_GW dev $OLD_WAN_DEV"
        ip route del "$OLD_GW" via "$OLD_WAN_GW" dev "$OLD_WAN_DEV" 2>/dev/null
    fi
    
    rm -f "$STATE_FILE"
fi

# --- Add new route ---

if [ -z "$VPNGATEWAY" ]; then
    log "Error: VPNGATEWAY not set"
    return 1
fi

# Get current WAN interface info
network_find_wan WAN_IFACE
[ -z "$WAN_IFACE" ] && WAN_IFACE="wan"

network_get_gateway WAN_GW "$WAN_IFACE"
network_get_device WAN_DEV "$WAN_IFACE"

if [ -z "$WAN_GW" ] || [ -z "$WAN_DEV" ]; then
    log "Error: Could not determine WAN gateway or device"
    return 1
fi

log "Adding new route: $VPNGATEWAY via $WAN_GW dev $WAN_DEV"

ip route replace "$VPNGATEWAY" via "$WAN_GW" dev "$WAN_DEV" metric 1

if [ $? -eq 0 ]; then
    log "Successfully added route for $VPNGATEWAY"
    echo "$VPNGATEWAY $WAN_GW $WAN_DEV" > "$STATE_FILE"
    return 0
else
    log "Failed to add route for $VPNGATEWAY"
    return 1
fi
EOF
    log_info "Hook '${file}' installed!"
}

main() {
    parse_args "$@"

    [ "${VERBOSE}" -gt 0 ] && log_debug "Verbose level ${VERBOSE}"

    check_dependencies

    install_openconnect
    configure_interface
    configure_firewall
    install_hooks
    
    if prompt_yes_no "Do you want to reboot device?" Y; then
        log_info "Rebooting..."
        reboot
    fi
}

main "$@"
