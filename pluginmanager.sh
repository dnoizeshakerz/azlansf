#!/bin/bash
#===============================================================================
# WordPress Cache & Security Plugin Manager (cPanel & DirectAdmin Compatible)
#===============================================================================

# Global Flags
DRY_RUN=0
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-d" ]]; then
    DRY_RUN=1
fi

# Disable Shell Fork Bomb Protection (cPanel specific, fails silently elsewhere)
if [ -d "/usr/local/cpanel" ]; then
    perl -I/usr/local/cpanel -MCpanel::LoginProfile -le 'print [Cpanel::LoginProfile::remove_profile("limits")]->[1];' 2>/dev/null
fi

RED='\033;31m'
GREEN='\033;32m'
YELLOW='\033;33m'
NC='\033[0m'

LOG_FILE="/var/log/wp-plugin-manager.log"

# Log Rotation: Prevent the log file from bloating server space over time
if [ -f "$LOG_FILE" ] && [ $(find "$LOG_FILE" -type f -size +50M 2>/dev/null) ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# PANEL ENVIRONMENT & ACCOUNT DETECTION
#===============================================================================

get_account_user() {
    local wp_dir="$1"
    local cpuser=""

    # Standard /home/username layout works for both cPanel & DirectAdmin
    if [[ "$wp_dir" == /home/* ]]; then
        cpuser=$(echo "$wp_dir" | cut -d'/' -f3)
    fi

    if [ -n "$cpuser" ] && id "$cpuser" &>/dev/null; then
        echo "$cpuser"
        return
    fi

    # Fallback to file owner if directory parsing fails
    if [ -f "$wp_dir/wp-config.php" ]; then
        cpuser=$(stat -c '%U' "$wp_dir/wp-config.php" 2>/dev/null)
    fi

    echo "$cpuser"
}

is_account_suspended() {
    local cpuser="$1"
    
    # cPanel Suspension Check
    if [ -d "/var/cpanel/suspended/$cpuser" ] || [ -f "/var/cpanel/suspended/$cpuser" ]; then
        return 0
    fi
    
    # DirectAdmin Suspension Check
    if [ -f "/usr/local/directadmin/data/users/$cpuser/user.conf" ]; then
        if grep -qE "^suspended=yes" "/usr/local/directadmin/data/users/$cpuser/user.conf" 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

get_user_php() {
    local cpuser="$1"
    local php_bin=""

    local paths=(
        # cPanel EasyApache Paths
        "/opt/cpanel/ea-php83/root/usr/bin/php"
        "/opt/cpanel/ea-php82/root/usr/bin/php"
        "/opt/cpanel/ea-php81/root/usr/bin/php"
        "/opt/cpanel/ea-php80/root/usr/bin/php"
        "/opt/cpanel/ea-php74/root/usr/bin/php"
        # CloudLinux / PHP Selector Paths
        "/opt/alt/php83/usr/bin/php"
        "/opt/alt/php82/usr/bin/php"
        "/opt/alt/php81/usr/bin/php"
        "/opt/alt/php80/usr/bin/php"
        "/opt/alt/php74/usr/bin/php"
        # DirectAdmin CustomBuild Paths
        "/usr/local/php83/bin/php"
        "/usr/local/php82/bin/php"
        "/usr/local/php81/bin/php"
        "/usr/local/php80/bin/php"
        "/usr/local/php74/bin/php"
        # Global Defaults
        "/usr/local/bin/php"
        "/usr/bin/php"
    )

    # Contextual cPanel detection
    if [ -n "$cpuser" ] && [ -f "/var/cpanel/users/$cpuser" ]; then
        local php_version
        php_version=$(grep -E "^PHPVERSION=" "/var/cpanel/users/$cpuser" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$php_version" ]; then
            local ea_path="/opt/cpanel/ea-php${php_version}/root/usr/bin/php"
            [ -x "$ea_path" ] && php_bin="$ea_path"
        fi
    fi

    # Path scanning fallback
    if [ -z "$php_bin" ]; then
        for p in "${paths[@]}"; do
            if [ -x "$p" ]; then
                local ver
                ver=$("$p" -r "echo PHP_VERSION;" 2>/dev/null | cut -d'.' -f1,2)
                if [ -n "$ver" ] && [ "${ver//./}" -ge "74" ] 2>/dev/null; then
                    php_bin="$p"
                    break
                fi
            fi
        done
    fi

    [ -z "$php_bin" ] && php_bin=$(which php 2>/dev/null || echo "/usr/bin/php")
    echo "$php_bin"
}

#===============================================================================
# LITESPEED CHECK
#===============================================================================

check_lsws() {
    if systemctl is-active --quiet lsws 2>/dev/null || systemctl is-active --quiet openlitespeed 2>/dev/null; then
        return 0
    elif [ -d "/usr/local/lsws" ] && [ -f "/usr/local/lsws/bin/lswsctrl" ]; then
        return 0
    else
        return 1
    fi
}

#===============================================================================
# FIND WORDPRESS SITES
#===============================================================================

find_wordpress_sites() {
    local wp_sites=()
    # Maxdepth 6 ensures deep-nested DirectAdmin domain public_html folders are successfully indexed
    while IFS= read -r -d '' wp_config; do
        wp_sites+=("$(dirname "$wp_config")")
    done < <(find /home -maxdepth 6 -type f -name "wp-config.php" -print0 2>/dev/null)
    printf '%s\n' "${wp_sites[@]}"
}

#===============================================================================
# WP-CLI DROPPED ROOT PRIVILEGES CONTROL
#===============================================================================

ensure_wp_cli() {
    if [ ! -f "/usr/local/bin/wp" ]; then
        log_info "Installing WP-CLI..."
        curl -sLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        if [ -f "wp-cli.phar" ]; then
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
            log_info "WP-CLI installed successfully."
        else
            log_error "Failed to download WP-CLI."
            return 1
        fi
    fi
    return 0
}

wp_cmd() {
    local wp_dir="$1"
    local php_bin="$2"
    local cpuser="$3"
    shift 3
    
    # Crucial Security Update: Drops root privileges entirely. WP-CLI executes natively as 
    # the target tenant account user. This mitigates file permission corruption bugs.
    runuser -u "$cpuser" -- "$php_bin" /usr/local/bin/wp --path="$wp_dir" "$@"
}

#===============================================================================
# PLUGIN DETECTION PATTERNS
#===============================================================================

get_active_plugins() {
    local wp_dir="$1"
    local php_bin="$2"
    local cpuser="$3"
    wp_cmd "$wp_dir" "$php_bin" "$cpuser" plugin list --status=active --field=name 2>/dev/null
}

LSCACHE_PATTERNS="litespeed-cache|LiteSpeed Cache"
SECURITY_PLUGINS="wordfence|sucuri|better-wp-security|all-in-one-wp-security|bulletproof-security|limit-login-attempts-reloaded|loginizer|jetpack|solid-security"

is_lscache_installed() { echo "$1" | grep -qiE "$LSCACHE_PATTERNS"; }
is_security_installed() { echo "$1" | grep -qiE "$SECURITY_PLUGINS"; }
is_other_cache_installed() {
    echo "$1" | grep -qiE "wp-super-cache|w3-total-cache|wp-fastest-cache|wp-rocket|comet-cache|hyper-cache|swift-performance|breeze|sg-optimizer|nitropack|flying-press|perfmatters|cache-enabler" && ! echo "$1" | grep -qiE "$LSCACHE_PATTERNS"
}

#===============================================================================
# IMMUTABLE / DRY RUN ACTION WRAPPERS
#===============================================================================

deactivate_plugin() {
    local wp_dir="$1"; local php_bin="$2"; local cpuser="$3"; local plugin_slug="$4"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would deactivate plugin: $plugin_slug"
        return 0
    fi
    wp_cmd "$wp_dir" "$php_bin" "$cpuser" plugin deactivate "$plugin_slug"
}

delete_plugin() {
    local wp_dir="$1"; local php_bin="$2"; local cpuser="$3"; local plugin_slug="$4"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would completely remove plugin: $plugin_slug"
        return 0
    fi
    wp_cmd "$wp_dir" "$php_bin" "$cpuser" plugin delete "$plugin_slug"
}

install_plugin() {
    local wp_dir="$1"; local php_bin="$2"; local cpuser="$3"; local plugin_slug="$4"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would install and activate plugin: $plugin_slug"
        return 0
    fi
    wp_cmd "$wp_dir" "$php_bin" "$cpuser" plugin install "$plugin_slug" --activate
}

#===============================================================================
# PROCESS INDIVIDUAL WORDPRESS SITE
#===============================================================================

process_site() {
    local wp_dir="$1"

    log_info "========================================"
    log_info "Processing Directory: $wp_dir"

    if [ ! -f "$wp_dir/wp-config.php" ]; then
        log_warn "Missing configuration context. Skipping."
        return
    fi

    local cpuser
    cpuser=$(get_account_user "$wp_dir")
    log_info "Identified Owner: $cpuser"

    if [ -z "$cpuser" ]; then
        log_error "Could not safely trace execution permissions owner. Skipping."
        return
    fi

    if is_account_suspended "$cpuser"; then
        log_warn "Account [$cpuser] is currently suspended. Skipping processing optimization loop."
        return
    fi

    local php_bin
    php_bin=$(get_user_php "$cpuser")
    log_info "Allocated Environment PHP: $php_bin"

    # Integrity Check: Ensure database communication is alive before querying plugins
    if ! wp_cmd "$wp_dir" "$php_bin" "$cpuser" core is-installed >/dev/null 2>&1; then
        log_error "WordPress core framework validation or database connection failed. Skipping site execution."
        return
    fi

    local plugins
    plugins=$(get_active_plugins "$wp_dir" "$php_bin" "$cpuser")

    if [ -z "$plugins" ]; then
        log_warn "Unable to resolve live database active plugin lists. Dropping down to localized system fallback scan..."
        local plugins_dir="$wp_dir/wp-content/plugins"
        if [ -d "$plugins_dir" ]; then
            plugins=$(find "$plugins_dir" -maxdepth 1 -type d | sed '1d' | xargs -n1 basename 2>/dev/null)
            echo "$plugins" | sed 's/^/  - [Scanned File] /'
        fi
    else
        log_info "Active Plugins Evaluated:"
        echo "$plugins" | sed 's/^/  - /'
    fi

    # --- CACHE ARCHITECTURE OPTIMIZATION ENGINE ---
    if is_lscache_installed "$plugins"; then
        log_warn "LiteSpeed active caching layer rules found."
        if ! check_lsws; then
            log_warn "LiteSpeed Web Server framework is absent on host environment. Transitioning profile..."

            deactivate_plugin "$wp_dir" "$php_bin" "$cpuser" "litespeed-cache"
            delete_plugin "$wp_dir" "$php_bin" "$cpuser" "litespeed-cache"
            
            if [ "$DRY_RUN" -eq 0 ]; then
                rm -rf "$wp_dir/wp-content/litespeed" 2>/dev/null
                rm -f "$wp_dir/.htaccess.litespeed" 2>/dev/null
            fi

            install_plugin "$wp_dir" "$php_bin" "$cpuser" "cache-enabler"
            if [ $? -eq 0 ] || [ "$DRY_RUN" -eq 1 ]; then
                log_info "Successfully provisioned alternative caching core (Cache Enabler)."
            else
                log_error "Critical failure occurred migrating core page caching stack."
            fi
        else
            log_info "LiteSpeed Web Server framework verified online. Leaving original configuration unbothered."
        fi
    elif is_other_cache_installed "$plugins"; then
        log_info "Alternative active micro-caching asset configuration found. Skipping layout transitions."
    else
        log_info "No baseline caching systems observed."
        if ! check_lsws; then
            log_info "Provisioning system optimization layer: Cache Enabler..."
            install_plugin "$wp_dir" "$php_bin" "$cpuser" "cache-enabler"
        else
            log_info "LiteSpeed engine detected running standalone. Mapping standard module framework: LiteSpeed Cache..."
            install_plugin "$wp_dir" "$php_bin" "$cpuser" "litespeed-cache"
        fi
    fi

    # --- PERIMETER SECURITY ENGINE CONTROL ---
    if is_security_installed "$plugins"; then
        log_info "Security monitoring framework is active. Skipping installation logic."
    else
        log_warn "Brute-force security mitigation layers are empty. Injecting system-preferred stack..."
        install_plugin "$wp_dir" "$php_bin" "$cpuser" "limit-login-attempts-reloaded"
        if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
            log_warn "Primary package installation rejected. Provisioning secondary firewall perimeter: Loginizer..."
            install_plugin "$wp_dir" "$php_bin" "$cpuser" "loginizer"
        fi
    fi

    log_info "Completed automation tasks for site: $(basename "$wp_dir")"
}

#===============================================================================
# INITIALIZATION INTERFACE ENTRYPOINT
#===============================================================================

main() {
    log_info "=========================================="
    log_info "WordPress Optimization Manager Initialized"
    log_info "Timestamp: $(date)"
    log_info "=========================================="

    if [ "$EUID" -ne 0 ]; then
        log_error "Root system initialization execution required. Process execution killed."
        exit 1
    fi

    ensure_wp_cli
    if [ $? -ne 0 ]; then exit 1; fi

    if check_lsws; then
        log_info "Global Host Environment: LiteSpeed Engine (Active)"
    else
        log_warn "Global Host Environment: Apache / Nginx Traditional Reverse Stack (Active)"
    fi

    log_info "Scanning disk partitions for global WordPress footprints..."
    local sites
    sites=$(find_wordpress_sites)
    
    local site_count=0
    if [ -n "$sites" ]; then
        site_count=$(echo "$sites" | wc -l)
    fi

    if [ "$site_count" -eq 0 ]; then
        log_warn "No functional WordPress targets returned via standard discovery sweeps."
        exit 0
    fi

    log_info "Target Pool Built successfully: Found $site_count active installation(s)."

    while IFS= read -r site; do
        [ -n "$site" ] && process_site "$site"
    done <<< "$sites"

    log_info "=========================================="
    log_info "Execution Cycle Terminated. Run Log Saved: $LOG_FILE"
    log_info "=========================================="
}

main "$@"
