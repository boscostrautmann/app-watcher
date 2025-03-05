#!/bin/bash

# app_watcher.sh - Script de surveillance des applications basé sur les groupes Jamf
# Version: 1.0.0-alpha.1
# Auteur: Bosco Strautmann
# Date: 2024-10-10
# Licence: MIT

# Variables globales
VERSION="1.0.0-alpha.1"
LOG_FILE="/var/log/app_watcher.log"
CONFIG_FILE="/etc/jamf.conf"
APPS_PLIST="/etc/apps.plist"

# Charger la configuration depuis jamf.conf
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Erreur : Fichier de configuration $CONFIG_FILE introuvable" >&2
    exit 1
fi

# Utiliser la variable system_apps chargée depuis jamf.conf
# (La liste des applications toujours autorisées est maintenant dans jamf.conf)

###########################################################################################

# Fonction de logging
log() {
    local level="$1" msg="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$LOG_FILE"
}

# Charger la configuration sécurisée
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    log "ERROR" "Fichier de configuration $CONFIG_FILE introuvable"
    exit 1
fi

# Obtenir le jeton OAuth 2.0 pour l'API Jamf
get_token() {
    client_id="$JAMF_CLIENT_ID"
    client_secret="$JAMF_CLIENT_SECRET"
    auth_response=$(curl -s -X POST "$JAMF_URL/api/oauth/token" \
        -d "grant_type=client_credentials" \
        -d "client_id=$client_id" \
        -d "client_secret=$client_secret")
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
        allowed_apps=$(defaults read "$APPS_PLIST" "$user_group" 2>/dev/null)
        if [ -z "$allowed_apps" ]; then
            log "WARNING" "Aucune appli définie pour $user_group, utilisation du groupe par défaut"
            allowed_apps=$(defaults read "$APPS_PLIST" "default" 2>/dev/null)
        fi
    fi
    log "INFO" "Applications autorisées pour $user_group : $allowed_apps"
}

# Surveiller et fermer les applications non autorisées
monitor_apps() {
    while true; do
        running_apps=$(lsappinfo list | grep 'bundleID="' | sed 's/.*bundleID="//' | sed 's/"$//' | sort -u)
        for app in $running_apps; do
            # Ignorer les applications système/Jamf toujours autorisées
            if [[ " $system_apps " =~ " $app " ]]; then
                continue
            fi
            # Autoriser toutes les applications pour le groupe admin
            if [ "$allowed_apps" = "*" ]; then
                continue
            fi
            # Fermer les applications non autorisées
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
        sleep 5  # Vérification toutes les 5 secondes
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
get_current_user
get_token
get_user_group
get_allowed_apps
monitor_apps