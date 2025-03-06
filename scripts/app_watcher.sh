#!/bin/bash

# app_watcher.sh - Script de surveillance des applications basé sur les groupes Jamf
# Version: 1.0.0-alpha.1
# Auteur: Bosco Strautmann
# Date: 2024-10-10
# Licence: MIT

# Variables globales
VERSION="1.0.0-alpha.1"
CONFIG_FILE="/Library/Managed Preferences/com.topbosco.AppWatcher.plist"

###########################################################################################

# Fonction de logging
log() {
    local level="$1" msg="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$LOG_FILE"
}

# Lire les configurations depuis le fichier plist
read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Fichier de configuration $CONFIG_FILE introuvable" >> "/var/log/app_watcher.log"
        exit 1
    fi

    # Lire les paramètres généraux
    SCRIPT_PATH=$(defaults read "$CONFIG_FILE" generalSettings | grep ScriptPath | awk -F'"' '{print $4}')
    LAUNCHAGENT_LABEL=$(defaults read "$CONFIG_FILE" generalSettings | grep LaunchAgentLabel | awk -F'"' '{print $4}')
    LAUNCHAGENT_PATH=$(defaults read "$CONFIG_FILE" generalSettings | grep LaunchAgentPath | awk -F'"' '{print $4}')
    STANDARD_OUT_PATH=$(defaults read "$CONFIG_FILE" generalSettings | grep StandardOutPath | awk -F'"' '{print $4}')
    STANDARD_ERROR_PATH=$(defaults read "$CONFIG_FILE" generalSettings | grep StandardErrorPath | awk -F'"' '{print $4}')
    START_INTERVAL=$(defaults read "$CONFIG_FILE" generalSettings | grep StartInterval | awk -F'=' '{print $2}' | tr -d ' ;')

    # Lire les paramètres Jamf
    JAMF_URL=$(defaults read "$CONFIG_FILE" jamfSettings | grep JAMF_URL | awk -F'"' '{print $4}')
    JAMF_CLIENT_ID=$(defaults read "$CONFIG_FILE" jamfSettings | grep JAMF_CLIENT_ID | awk -F'"' '{print $4}')
    JAMF_CLIENT_SECRET=$(defaults read "$CONFIG_FILE" jamfSettings | grep JAMF_CLIENT_SECRET | awk -F'"' '{print $4}')

    # Lire les applications système
    system_apps=$(defaults read "$CONFIG_FILE" systemApps | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')

    # Vérifier les configurations essentielles
    if [ -z "$SCRIPT_PATH" ] || [ -z "$LAUNCHAGENT_LABEL" ] || [ -z "$LAUNCHAGENT_PATH" ] || \
       [ -z "$STANDARD_OUT_PATH" ] || [ -z "$STANDARD_ERROR_PATH" ] || [ -z "$START_INTERVAL" ] || \
       [ -z "$JAMF_URL" ] || [ -z "$JAMF_CLIENT_ID" ] || [ -z "$JAMF_CLIENT_SECRET" ]; then
        log "ERROR" "Échec de la lecture des configurations essentielles depuis $CONFIG_FILE"
        exit 1
    fi

    # Définir LOG_FILE et ERROR_LOG_FILE
    LOG_FILE="$STANDARD_OUT_PATH"
    ERROR_LOG_FILE="$STANDARD_ERROR_PATH"
}

# Générer et charger le LaunchAgent
generate_launchagent() {
    currentUser=$(stat -f "%Su" /dev/console)  # Récupérer l'utilisateur actuel connecté

    # Remplacer %currentUser% dans les chemins si présent
    STANDARD_OUT_PATH=$(echo "$STANDARD_OUT_PATH" | sed "s/%currentUser%/$currentUser/")
    STANDARD_ERROR_PATH=$(echo "$STANDARD_ERROR_PATH" | sed "s/%currentUser%/$currentUser/")

    # Créer le fichier .plist du LaunchAgent
    cat <<EOF > "$LAUNCHAGENT_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHAGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$STANDARD_OUT_PATH</string>
    <key>StandardErrorPath</key>
    <string>$STANDARD_ERROR_PATH</string>
</dict>
</plist>
EOF

    # Appliquer les permissions
    chmod 644 "$LAUNCHAGENT_PATH"
    chown root:wheel "$LAUNCHAGENT_PATH"

    # Charger le LaunchAgent
    launchctl load "$LAUNCHAGENT_PATH"
    log "INFO" "LaunchAgent chargé avec succès : $LAUNCHAGENT_PATH"
}

# Obtenir le jeton OAuth 2.0 pour l'API Jamf
get_token() {
    auth_response=$(curl -s -X POST "$JAMF_URL/api/oauth/token" \
        -d "grant_type=client_credentials" \
        -d "client_id=$JAMF_CLIENT_ID" \
        -d "client_secret=$JAMF_CLIENT_SECRET")
    token=$(echo "$auth_response" | jq -r '.access_token')
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log "ERROR" "Échec de l'authentification OAuth"
        exit 1
    fi
    log "INFO" "Jeton OAuth obtenu avec succès"
}

# Détecter l'utilisateur actuel
get_current_user() {
    currentUser=$(stat -f "%Su" /dev/console)
    if [ -z "$currentUser" ] || [ "$currentUser" = "root" ]; then
        log "ERROR" "Aucun utilisateur connecté ou utilisateur root détecté"
        exit 1
    fi
    log "INFO" "Utilisateur actuel : $currentUser"
}

# Obtenir le groupe de l'utilisateur via l'API Jamf
get_user_group() {
    user_response=$(curl -s -H "Authorization: Bearer $token" "$JAMF_URL/JSSResource/users/email/$currentUser@iil.ch")
    user_group=$(echo "$user_response" | xmllint --xpath "//user_group/name/text()" - 2>/dev/null)
    if [ -z "$user_group" ]; then
        log "WARNING" "Groupe non trouvé pour $currentUser, utilisation du groupe par défaut"
        user_group="default"
    else
        log "INFO" "Groupe de l'utilisateur $currentUser : $user_group"
    fi
}

# Obtenir les applications autorisées pour le groupe
get_allowed_apps() {
    if [ "$user_group" = "admin" ]; then
        allowed_apps="*"  # Toutes les applications autorisées pour le groupe admin
    else
        allowed_apps=$(defaults read "$CONFIG_FILE" appConfiguration | grep -A 1000 "$user_group" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')
        if [ -z "$allowed_apps" ]; then
            log "WARNING" "Aucune application définie pour $user_group, utilisation du groupe par défaut"
            allowed_apps=$(defaults read "$CONFIG_FILE" appConfiguration | grep -A 1000 "Default" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')
        fi
    fi
    log "INFO" "Applications autorisées pour $user_group : $allowed_apps"
}

# Surveiller et fermer les applications non autorisées
monitor_apps() {
    while true; do
        running_apps=$(lsappinfo list | grep 'bundleID="' | sed 's/.*bundleID="//' | sed 's/"$//' | sort -u)
        for app in $running_apps; do
            if [[ " $system_apps " =~ " $app " ]]; then
                continue
            fi
            if [ "$allowed_apps" = "*" ]; then
                continue
            fi
            if ! echo "$allowed_apps" | grep -q "$app"; then
                log "INFO" "Fermeture de l'application non autorisée : $app"
                pid=$(lsappinfo info -only pid "$app" | sed 's/.*=\([0-9]*\).*/\1/')
                if [ -n "$pid" ]; then
                    kill -15 "$pid"
                    if [ $? -eq 0 ]; then
                        log "INFO" "$app fermé avec succès"
                    else
                        log "WARNING" "Échec de la fermeture de $app"
                    fi
                fi
            fi
        done
        sleep "$START_INTERVAL"
    done
}

# Vérification des dépendances
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR" "'jq' requis pour parser JSON. Installez-le avec 'brew install jq'."
    exit 1
fi
if ! command -v xmllint >/dev/null 2>&1; then
    log "ERROR" "'xmllint' requis pour parser XML. Installez-le avec 'brew install libxml2'."
    exit 1
fi

# Démarrage du script
log "INFO" "Démarrage de app_watcher.sh - Version $VERSION"
read_config
generate_launchagent
get_current_user
get_token
get_user_group
get_allowed_apps
monitor_apps