#!/bin/bash
#===============================================================================
# WordPress Cache & Security Plugin Manager for cPanel
# Uses cPanel user's PHP binary for WP-CLI operations
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/wp-plugin-manager.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# CPANEL USER & PHP DETECTION
#===============================================================================

get_cpanel_user() {
    local wp_dir="$1"
    local cpuser=""

    if [[ "$wp_dir" == /home/* ]]; then
        cpuser=$(echo "$wp_dir" | cut -d'/' -f3)
    fi

    if [ -n "$cpuser" ] && id "$cpuser" &>/dev/null; then
        echo "$cpuser"
        return
    fi

    if [ -f "$wp_dir/wp-config.php" ]; then
        cpuser=$(stat -c '%U' "$wp_dir/wp-config.php" 2>/dev/null)
    fi

    echo "$cpuser"
}

get_user_php() {
    local cpuser="$1"
    local php_bin=""

    # cPanel EA/ALT-PHP paths
    local paths=(
        "/opt/cpanel/ea-php74/root/usr/bin/php"
        "/opt/cpanel/ea-php80/root/usr/bin/php"
        "/opt/cpanel/ea-php81/root/usr/bin/php"
        "/opt/cpanel/ea-php82/root/usr/bin/php"
        "/opt/cpanel/ea-php83/root/usr/bin/php"
        "/opt/alt/php74/usr/bin/php"
        "/opt/alt/php80/usr/bin/php"
        "/opt/alt/php81/usr/bin/php"
        "/opt/alt/php82/usr/bin/php"
        "/usr/local/bin/php"
        "/usr/bin/php"
    )

    # Check if user has a specific PHP version set
    if [ -n "$cpuser" ] && [ -f "/var/cpanel/users/$cpuser" ]; then
        local php_version
        php_version=$(grep -E "^PHPVERSION=" "/var/cpanel/users/$cpuser" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$php_version" ]; then
            local ea_path="/opt/cpanel/ea-php${php_version}/root/usr/bin/php"
            [ -x "$ea_path" ] && php_bin="$ea_path"
        fi
    fi

    # Fallback: find newest available PHP
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

    # Last resort: system php
    [ -z "$php_bin" ] && php_bin=$(which php 2>/dev/null || echo "/usr/bin/php")

    echo "$php_bin"
}

#===============================================================================
# OWNERSHIP HELPERS
#===============================================================================

fix_ownership() {
    local wp_dir="$1"
    local cpuser
    cpuser=$(get_cpanel_user "$wp_dir")

    if [ -z "$cpuser" ] || ! id "$cpuser" &>/dev/null; then
        log_warn "Could not determine cPanel user for $wp_dir"
        return 1
    fi

    if [ -d "$wp_dir/wp-content/plugins" ]; then
        chown -R "$cpuser:$cpuser" "$wp_dir/wp-content/plugins"
        log_info "Ownership fixed: wp-content/plugins → $cpuser:$cpuser"
    fi

    if [ -d "$wp_dir/wp-content/cache" ]; then
        chown -R "$cpuser:$cpuser" "$wp_dir/wp-content/cache" 2>/dev/null
    fi

    if [ -d "$wp_dir/wp-content" ]; then
        chown "$cpuser:$cpuser" "$wp_dir/wp-content" 2>/dev/null
    fi
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
    while IFS= read -r -d '' wp_config; do
        wp_sites+=("$(dirname "$wp_config")")
    done < <(find /home -maxdepth 4 -name "wp-config.php" -print0 2>/dev/null)
    printf '%s\n' "${wp_sites[@]}"
}

#===============================================================================
# WP-CLI WITH USER'S PHP
#===============================================================================

ensure_wp_cli() {
    if [ ! -f "/usr/local/bin/wp" ]; then
        log_info "Installing WP-CLI..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        if [ -f "wp-cli.phar" ]; then
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
            log_info "WP-CLI installed."
        else
            log_error "Failed to install WP-CLI."
            return 1
        fi
    fi
    return 0
}

# Run wp-cli with detected PHP binary
wp_cmd() {
    local wp_dir="$1"
    local php_bin="$2"
    shift 2
    cd "$wp_dir" && "$php_bin" /usr/local/bin/wp "$@" --allow-root 2>/dev/null
}

#===============================================================================
# PLUGIN DETECTION
#===============================================================================

get_active_plugins() {
    local wp_dir="$1"
    local php_bin="$2"

    wp_cmd "$wp_dir" "$php_bin" plugin list --status=active --field=name 2>/dev/null
}

LSCACHE_PATTERNS="litespeed-cache|LiteSpeed Cache"
SECURITY_PLUGINS="wordfence|sucuri|iThemes-Security|better-wp-security|all-in-one-wp-security|bulletproof-security|limit-login-attempts-reloaded|limit-login-attempts-loginizer|jetpack|solid-security|malcare|webdefender"
PREFERRED_SECURITY_SLUG="limit-login-attempts-reloaded/limit-login-attempts-reloaded.php"
FALLBACK_SECURITY_SLUG="loginizer/loginizer.php"

is_lscache_installed() {
    echo "$1" | grep -qiE "$LSCACHE_PATTERNS"
}

is_other_cache_installed() {
    echo "$1" | grep -qiE "wp-super-cache|w3-total-cache|wp-fastest-cache|wp-rocket|comet-cache|hyper-cache|swift-performance|breeze|sg-optimizer|nitropack|flying-press|perfmatters|cache-enabler" && ! echo "$1" | grep -qiE "$LSCACHE_PATTERNS"
}

is_security_installed() {
    echo "$1" | grep -qiE "$SECURITY_PLUGINS"
}

#===============================================================================
# PLUGIN OPERATIONS WITH OWNERSHIP FIX
#===============================================================================

deactivate_plugin() {
    local wp_dir="$1"
    local php_bin="$2"
    local plugin_slug="$3"
    wp_cmd "$wp_dir" "$php_bin" plugin deactivate "$plugin_slug"
}

delete_plugin() {
    local wp_dir="$1"
    local php_bin="$2"
    local plugin_slug="$3"
    wp_cmd "$wp_dir" "$php_bin" plugin delete "$plugin_slug"
}

install_plugin() {
    local wp_dir="$1"
    local php_bin="$2"
    local plugin_slug="$3"
    local cpuser
    cpuser=$(get_cpanel_user "$wp_dir")

    wp_cmd "$wp_dir" "$php_bin" plugin install "$plugin_slug" --activate
    local result=$?

    if [ $result -eq 0 ] && [ -n "$cpuser" ] && id "$cpuser" &>/dev/null; then
        local plugin_name
        plugin_name=$(echo "$plugin_slug" | cut -d'/' -f1)
        if [ -d "$wp_dir/wp-content/plugins/$plugin_name" ]; then
            chown -R "$cpuser:$cpuser" "$wp_dir/wp-content/plugins/$plugin_name"
            log_info "Ownership fixed: $plugin_name → $cpuser:$cpuser"
        fi
    fi

    return $result
}

#===============================================================================
# PROCESS SINGLE SITE
#===============================================================================

process_site() {
    local wp_dir="$1"

    log_info "========================================"
    log_info "Processing: $wp_dir"

    if [ ! -f "$wp_dir/wp-config.php" ]; then
        log_warn "Not a valid WordPress installation. Skipping."
        return
    fi

    local cpuser
    cpuser=$(get_cpanel_user "$wp_dir")
    log_info "cPanel user: $cpuser"

    local php_bin
    php_bin=$(get_user_php "$cpuser")
    log_info "Using PHP: $php_bin ($("$php_bin" -r "echo PHP_VERSION;" 2>/dev/null))"

    local plugins
    plugins=$(get_active_plugins "$wp_dir" "$php_bin")

    if [ -z "$plugins" ]; then
        log_warn "Could not retrieve plugin list (WP-CLI failed or no plugins active)."
        # Try fallback: direct directory scan
        local plugins_dir="$wp_dir/wp-content/plugins"
        if [ -d "$plugins_dir" ]; then
            plugins=$(find "$plugins_dir" -maxdepth 1 -type d | sed '1d' | xargs -n1 basename 2>/dev/null)
            log_info "Fallback plugin scan found:"
            echo "$plugins" | sed 's/^/  - /'
        fi
    else
        log_info "Active plugins:"
        echo "$plugins" | sed 's/^/  - /'
    fi

    # --- CACHE PLUGIN LOGIC ---
    if is_lscache_installed "$plugins"; then
        log_warn "LiteSpeed Cache detected."
        if ! check_lsws; then
            log_warn "LSWS not running. Removing LSCache → installing Cache Enabler..."

            deactivate_plugin "$wp_dir" "$php_bin" "litespeed-cache"
            delete_plugin "$wp_dir" "$php_bin" "litespeed-cache"
            rm -rf "$wp_dir/wp-content/litespeed" 2>/dev/null
            rm -f "$wp_dir/.htaccess.litespeed" 2>/dev/null

            install_plugin "$wp_dir" "$php_bin" "cache-enabler/cache-enabler.php"
            if [ $? -eq 0 ]; then
                log_info "Cache Enabler installed."
            else
                log_error "Cache Enabler installation failed."
            fi
        else
            log_info "LSWS running. Keeping LiteSpeed Cache."
        fi
    elif is_other_cache_installed "$plugins"; then
        log_info "Another cache plugin exists. Skipping Cache Enabler."
    else
        log_info "No cache plugin found."
        if ! check_lsws; then
            log_info "Installing Cache Enabler..."
            install_plugin "$wp_dir" "$php_bin" "cache-enabler/cache-enabler.php"
            if [ $? -eq 0 ]; then
                log_info "Cache Enabler installed."
            else
                log_error "Cache Enabler installation failed."
            fi
        else
            log_info "LSWS running but no cache plugin. Consider installing LiteSpeed Cache manually."
        fi
    fi

    # --- SECURITY PLUGIN LOGIC ---
    if is_security_installed "$plugins"; then
        log_info "Security plugin already present. Skipping."
    else
        log_warn "No security plugin found. Installing preferred security plugin..."

        install_plugin "$wp_dir" "$php_bin" "$PREFERRED_SECURITY_SLUG"
        if [ $? -eq 0 ]; then
            log_info "Limit Login Attempts Reloaded installed."
        else
            log_warn "Preferred plugin failed. Trying Loginizer..."
            install_plugin "$wp_dir" "$php_bin" "$FALLBACK_SECURITY_SLUG"
            if [ $? -eq 0 ]; then
                log_info "Loginizer installed as fallback."
            else
                log_error "All security plugin installations failed."
            fi
        fi
    fi

    fix_ownership "$wp_dir"
    log_info "Site complete: $(basename "$wp_dir")"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    log_info "=========================================="
    log_info "WordPress Plugin Manager Started"
    log_info "Date: $(date)"
    log_info "=========================================="

    if [ "$EUID" -ne 0 ]; then
        log_error "Must run as root."
        exit 1
    fi

    ensure_wp_cli
    if check_lsws; then
        log_info "LSWS is running."
    else
        log_warn "LSWS is NOT running."
    fi

    log_info "Scanning for WordPress installations..."
    local sites
    sites=$(find_wordpress_sites)
    local site_count
    site_count=$(echo "$sites" | grep -c '^' || echo "0")

    if [ -z "$sites" ] || [ "$site_count" -eq 0 ]; then
        log_warn "No WordPress sites found."
        exit 0
    fi

    log_info "Found $site_count WordPress site(s)."

    while IFS= read -r site; do
        [ -n "$site" ] && process_site "$site"
    done <<< "$sites"

    log_info "=========================================="
    log_info "Complete. Log: $LOG_FILE"
    log_info "=========================================="
}

main "$@"
