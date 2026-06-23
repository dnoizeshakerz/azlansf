#!/bin/bash
#===============================================================================
# WordPress Cache & Security Plugin Manager for cPanel
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/wp-plugin-manager.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# CHECK LITESPEED WEB SERVER
#===============================================================================

check_lsws() {
    if systemctl is-active --quiet lsws 2>/dev/null || systemctl is-active --quiet openlitespeed 2>/dev/null; then
        log_info "LiteSpeed Web Server (LSWS) is running."
        return 0
    elif [ -d "/usr/local/lsws" ] && [ -f "/usr/local/lsws/bin/lswsctrl" ]; then
        log_info "LiteSpeed Web Server (LSWS) is installed but may not be running."
        return 0
    else
        log_warn "LiteSpeed Web Server (LSWS) is NOT installed or running."
        return 1
    fi
}

#===============================================================================
# FIND ALL WORDPRESS INSTALLATIONS
#===============================================================================

find_wordpress_sites() {
    local wp_sites=()
    
    # Search common cPanel document root locations
    while IFS= read -r -d '' wp_config; do
        local wp_dir
        wp_dir=$(dirname "$wp_config")
        wp_sites+=("$wp_dir")
    done < <(find /home -maxdepth 4 -name "wp-config.php" -print0 2>/dev/null)
    
    printf '%s\n' "${wp_sites[@]}"
}

#===============================================================================
# CHECK INSTALLED PLUGINS
#===============================================================================

get_active_plugins() {
    local wp_dir="$1"
    local wp_cli="/usr/local/bin/wp"
    
    if [ ! -f "$wp_cli" ]; then
        # Try to find wp-cli
        wp_cli=$(which wp 2>/dev/null || find /usr/local -name "wp" -type f 2>/dev/null | head -1)
    fi
    
    if [ -f "$wp_cli" ]; then
        cd "$wp_dir" && "$wp_cli" plugin list --status=active --field=name --allow-root 2>/dev/null
    else
        # Fallback: parse wp-content/plugins directory
        local plugins_dir="$wp_dir/wp-content/plugins"
        if [ -d "$plugins_dir" ]; then
            for plugin_dir in "$plugins_dir"/*; do
                if [ -d "$plugin_dir" ]; then
                    basename "$plugin_dir"
                fi
            done
        fi
    fi
}

#===============================================================================
# PLUGIN MANAGEMENT FUNCTIONS
#===============================================================================

# Cache plugin patterns
LSCACHE_PATTERNS="litespeed-cache|LiteSpeed Cache"
CACHE_ENABLER_NAME="cache-enabler"
CACHE_ENABLER_SLUG="cache-enabler/cache-enabler.php"

# Security plugin patterns
SECURITY_PLUGINS="wordfence|sucuri|iThemes-Security|better-wp-security|all-in-one-wp-security|bulletproof-security|limit-login-attempts-reloaded|limit-login-attempts-loginizer|jetpack"
PREFERRED_SECURITY="limit-login-attempts-reloaded"
PREFERRED_SECURITY_SLUG="limit-login-attempts-reloaded/limit-login-attempts-reloaded.php"

is_lscache_installed() {
    local plugins="$1"
    echo "$plugins" | grep -qiE "$LSCACHE_PATTERNS"
}

is_other_cache_installed() {
    local plugins="$1"
    # Check for other cache plugins excluding lscache
    echo "$plugins" | grep -qiE "wp-super-cache|w3-total-cache|wp-fastest-cache|wp-rocket|comet-cache|hyper-cache|swift-performance|breeze| SG Optimizer|nitropack|flying-press|perfmatters" && ! echo "$plugins" | grep -qiE "$LSCACHE_PATTERNS"
}

is_security_installed() {
    local plugins="$1"
    echo "$plugins" | grep -qiE "$SECURITY_PLUGINS"
}

#===============================================================================
# WP-CLI OPERATIONS
#===============================================================================

ensure_wp_cli() {
    if [ ! -f "/usr/local/bin/wp" ]; then
        log_info "Installing WP-CLI..."
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>/dev/null
        if [ -f "wp-cli.phar" ]; then
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
            log_info "WP-CLI installed successfully."
        else
            log_error "Failed to download WP-CLI. Some operations may fail."
            return 1
        fi
    fi
    return 0
}

deactivate_plugin() {
    local wp_dir="$1"
    local plugin_slug="$2"
    cd "$wp_dir" && /usr/local/bin/wp plugin deactivate "$plugin_slug" --allow-root 2>/dev/null
}

delete_plugin() {
    local wp_dir="$1"
    local plugin_slug="$2"
    cd "$wp_dir" && /usr/local/bin/wp plugin delete "$plugin_slug" --allow-root 2>/dev/null
}

install_plugin() {
    local wp_dir="$1"
    local plugin_slug="$2"
    cd "$wp_dir" && /usr/local/bin/wp plugin install "$plugin_slug" --activate --allow-root 2>/dev/null
}

#===============================================================================
# PROCESS SINGLE WORDPRESS SITE
#===============================================================================

process_site() {
    local wp_dir="$1"
    local site_name
    site_name=$(basename "$wp_dir")
    
    log_info "========================================"
    log_info "Processing site: $wp_dir"
    
    # Verify it's actually WordPress
    if [ ! -f "$wp_dir/wp-config.php" ]; then
        log_warn "Not a valid WordPress installation. Skipping."
        return
    fi
    
    # Get active plugins
    local plugins
    plugins=$(get_active_plugins "$wp_dir")
    
    if [ -z "$plugins" ]; then
        log_warn "Could not retrieve plugin list for $wp_dir"
        return
    fi
    
    log_info "Active plugins found:"
    echo "$plugins" | sed 's/^/  - /'
    
    # --- CACHE PLUGIN LOGIC ---
    local cache_action="none"
    
    if is_lscache_installed "$plugins"; then
        log_warn "LiteSpeed Cache plugin detected."
        if ! check_lsws; then
            log_warn "LSWS not running. Removing LiteSpeed Cache and installing Cache Enabler..."
            
            # Deactivate and delete LiteSpeed Cache
            deactivate_plugin "$wp_dir" "litespeed-cache"
            delete_plugin "$wp_dir" "litespeed-cache"
            
            # Clean up any LSCache files
            rm -rf "$wp_dir/wp-content/litespeed" 2>/dev/null
            rm -f "$wp_dir/.htaccess.litespeed" 2>/dev/null
            
            # Install Cache Enabler
            install_plugin "$wp_dir" "cache-enabler"
            
            if [ $? -eq 0 ]; then
                log_info "Cache Enabler installed and activated successfully."
                cache_action="replaced_lscache_with_enabler"
            else
                log_error "Failed to install Cache Enabler."
                cache_action="lscache_removed_enabler_failed"
            fi
        else
            log_info "LSWS is running. Keeping LiteSpeed Cache."
            cache_action="lscache_kept"
        fi
    elif is_other_cache_installed "$plugins"; then
        log_info "Another cache plugin detected (not LiteSpeed Cache). Skipping Cache Enabler installation."
        cache_action="other_cache_exists"
    else
        log_info "No cache plugin detected."
        if ! check_lsws; then
            log_info "Installing Cache Enabler..."
            install_plugin "$wp_dir" "cache-enabler"
            if [ $? -eq 0 ]; then
                log_info "Cache Enabler installed and activated."
                cache_action="enabler_installed"
            else
                log_error "Failed to install Cache Enabler."
                cache_action="enabler_failed"
            fi
        else
            log_info "LSWS running but no cache plugin. Consider installing LiteSpeed Cache manually."
            cache_action="no_cache_lsws_running"
        fi
    fi
    
    # --- SECURITY PLUGIN LOGIC ---
    local security_action="none"
    
    if is_security_installed "$plugins"; then
        log_info "Security plugin already installed. Skipping."
        security_action="already_exists"
    else
        log_warn "No security plugin detected. Installing preferred security plugin..."
        
        # Try preferred plugin first
        install_plugin "$wp_dir" "$PREFERRED_SECURITY_SLUG"
        
        if [ $? -eq 0 ]; then
            log_info "Limit Login Attempts Reloaded installed and activated."
            security_action="limit_login_installed"
        else
            log_warn "Failed to install Limit Login Attempts Reloaded. Trying Loginizer..."
            install_plugin "$wp_dir" "loginizer/loginizer.php"
            
            if [ $? -eq 0 ]; then
                log_info "Loginizer installed as fallback."
                security_action="loginizer_installed"
            else
                log_error "Failed to install any security plugin."
                security_action="failed"
            fi
        fi
    fi
    
    # Summary for this site
    log_info "Site processing complete: $site_name"
    log_info "  Cache action: $cache_action"
    log_info "  Security action: $security_action"
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    log_info "=========================================="
    log_info "WordPress Plugin Manager Script Started"
    log_info "Date: $(date)"
    log_info "=========================================="
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
    
    # Ensure WP-CLI is available
    ensure_wp_cli
    
    # Check LSWS status once
    log_info "Checking LiteSpeed Web Server status..."
    if check_lsws; then
        log_info "LSWS is present. Will keep LiteSpeed Cache where found."
    else
        log_warn "LSWS is NOT present. Will replace LiteSpeed Cache with Cache Enabler."
    fi
    
    # Find all WordPress sites
    log_info "Scanning for WordPress installations..."
    local sites
    sites=$(find_wordpress_sites)
    
    local site_count
    site_count=$(echo "$sites" | grep -c '^' || echo "0")
    
    if [ -z "$sites" ] || [ "$site_count" -eq 0 ]; then
        log_warn "No WordPress installations found."
        exit 0
    fi
    
    log_info "Found $site_count WordPress site(s)."
    
    # Process each site
    while IFS= read -r site; do
        [ -n "$site" ] && process_site "$site"
    done <<< "$sites"
    
    log_info "=========================================="
    log_info "Script completed. Log saved to: $LOG_FILE"
    log_info "=========================================="
}

# Run main function
main "$@"
