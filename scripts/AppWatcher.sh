#!/bin/bash

# AppWatcher - Script de surveillance des applications basé sur les configurations Jamf
# Version: 1.0.1
# Auteur: Bosco Strautmann
# Date: 2025-03-06
# Licence: MIT

# Variables globales
VERSION="1.0.1"
AppName="AppWatcher"

# Variables passées via Jamf (ou définies par défaut pour les tests)
apiuser="${4:-apiuser}"          # Nom d'utilisateur API
apipass="${5:-password}"         # Mot de passe API (stocké dans le trousseau après initialisation)
jssURL="${6:-https://jamf.example.com}"  # URL du serveur Jamf
company="${7:-example}"          # Nom de l'entreprise
domaine="${8:-@example.com}"     # Domaine de l'entreprise
StartInterval="${9:-60}"         # Intervalle en secondes
debug="${10:-DEBUG}"             # Niveau de log : ERROR, WARNING, DEBUG, FALSE

# Chemins des fichiers
SCRIPT_PATH="/usr/local/bin/$AppName.sh"
LAUNCHAGENT_PATH="/Library/LaunchAgents/com.$company.$AppName.plist"
PLIST_PATH="/Library/Managed Preferences/com.$company.$AppName.plist"
LOG_DIR="/var/log/$company/$AppName"
LOG_FILE="$LOG_DIR/$AppName.log"
ERROR_LOG_FILE="$LOG_DIR/$AppName.error.log"
JAMF_HELPER="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"

# Récupérer l'utilisateur connecté dynamiquement
currentUser=$(stat -f "%Su" /dev/console)
if [ -z "$currentUser" ] || [ "$currentUser" = "root" ]; then
    echo "❌ Aucun utilisateur valide connecté" >&2
    exit 1
fi

# Vérifier les dépendances
for dep in curl jq lsappinfo plutil security xmllint; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "❌ Dépendance manquante : $dep" >&2
        exit 1
    fi
done

# Créer le répertoire de logs
if [ "$debug" != "FALSE" ]; then
    sudo mkdir -p "$LOG_DIR"
    sudo chown "$currentUser:staff" "$LOG_DIR"
    sudo chmod 755 "$LOG_DIR"
    sudo touch "$LOG_FILE" "$ERROR_LOG_FILE"
    sudo chown "$currentUser:staff" "$LOG_FILE" "$ERROR_LOG_FILE"
    sudo chmod 644 "$LOG_FILE" "$ERROR_LOG_FILE"
    echo "✅ Utilisateur cible détecté : $currentUser" >> "$LOG_FILE"
else
    LOG_FILE="/dev/null"
    ERROR_LOG_FILE="/dev/null"
fi

# Fonction de log
log() {
    local level="$1"
    local message="$2"
    case "$debug" in
        "DEBUG") echo "$(date) [$level] $message" >> "$LOG_FILE" ;;
        "WARNING") [[ "$level" =~ (WARNING|ERROR) ]] && echo "$(date) [$level] $message" >> "$LOG_FILE" ;;
        "ERROR") [[ "$level" == "ERROR" ]] && echo "$(date) [$level] $message" >> "$LOG_FILE" ;;
        "FALSE") : ;;
    esac
}

# Vérification des paramètres
if [ -z "$apiuser" ] || [ -z "$apipass" ] || [ -z "$jssURL" ] || [ -z "$company" ] || [ -z "$domaine" ] || [ -z "$StartInterval" ] || [ -z "$debug" ]; then
    log "ERROR" "❌ Paramètres manquants : apiuser=$apiuser, jssURL=$jssURL, company=$company, domaine=$domaine, StartInterval=$StartInterval, debug=$debug"
    exit 1
fi

### Ajouter les credentials API au Keychain (si non existants)
if ! security find-generic-password -s "JamfAPIUser" -a "$apiuser" &>/dev/null; then
    if ! security add-generic-password -s "JamfAPIUser" -a "$apiuser" -w "$apipass" -T /usr/bin/security; then
        if [ "$debug" != "FALSE" ]; then
            echo "❌ Échec de l'ajout du mot de passe dans le Keychain" >> "$LOG_FILE"
        fi
        exit 1
    fi
fi

# Ajouter les autorisations de sécurité
for app in "/usr/bin/security" "/bin/bash"; do
    if ! security authorizationdb read system.login.console | grep -q "$app"; then
        if [ "$debug" != "FALSE" ]; then
            echo "✅ Ajout de l'autorisation pour $app" >> "$LOG_FILE"
        fi
        security authorizationdb write system.login.console allow "$app"
    fi
done

###################################################
# Création du script de surveillance
###################################################

cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash

# Variables
LOG_FILE="$LOG_FILE"
ERROR_LOG_FILE="$ERROR_LOG_FILE"
JAMF_HELPER="$JAMF_HELPER"
PLIST_PATH="$PLIST_PATH"
company="$company"
domaine="$domaine"
debug="$debug"

# Gestion des logs
if [ "\$debug" != "FALSE" ]; then
    sudo mkdir -p "\$(dirname "\$LOG_FILE")" 2>/dev/null
    sudo chmod 755 "\$(dirname "\$LOG_FILE")" 2>/dev/null
    sudo touch "\$LOG_FILE" "\$ERROR_LOG_FILE" 2>/dev/null
    sudo chmod 644 "\$LOG_FILE" "\$ERROR_LOG_FILE" 2>/dev/null
    echo "✅ Démarrage de $AppName.sh à \$(date)" >> "\$LOG_FILE"
else
    LOG_FILE="/dev/null"
    ERROR_LOG_FILE="/dev/null"
fi

# Fonction de log
log() {
    local level="\$1"
    local message="\$2"
    case "\$debug" in
        "DEBUG") echo "\$(date) [\$level] \$message" >> "\$LOG_FILE" ;;
        "WARNING") [[ "\$level" =~ (WARNING|ERROR) ]] && echo "\$(date) [\$level] \$message" >> "\$LOG_FILE" ;;
        "ERROR") [[ "\$level" == "ERROR" ]] && echo "\$(date) [\$level] \$message" >> "\$LOG_FILE" ;;
        "FALSE") : ;;
    esac
}

# Détecter la langue du système
lang=\$(defaults read -g AppleLocale 2>/dev/null | cut -d '_' -f1 || echo "en")

# Récupérer l'utilisateur connecté
currentUser=\$(stat -f "%Su" /dev/console)
if [ -z "\$currentUser" ] || [ "\$currentUser" = "root" ]; then
    log "ERROR" "❌ Aucun utilisateur valide connecté"
    exit 1
fi
log "INFO" "✅ Utilisateur connecté : \$currentUser"

# Récupérer les identifiants API depuis le trousseau
get_api_credentials() {
    local apiuser="\$1"
    local apipass
    apipass=\$(security find-generic-password -s "JamfAPIUser" -a "\$apiuser" -w 2>/dev/null)
    if [ -z "\$apipass" ]; then
        log "ERROR" "❌ Échec de récupération du mot de passe depuis le trousseau"
        return 1
    fi
    log "DEBUG" "✅ Mot de passe récupéré"
    echo "\$apipass"
}

# Obtenir un token Jamf API
get_jamf_api_token() {
    local apiuser="\$1"
    local jssURL="\$2"
    local apipass
    apipass=\$(get_api_credentials "\$apiuser")
    [ \$? -ne 0 ] && return 1
    local authResponse
    authResponse=\$(curl -s -X POST -u "\$apiuser:\$apipass" "\$jssURL/api/v1/auth/token" 2>>"\$ERROR_LOG_FILE")
    local token
    token=\$(echo "\$authResponse" | jq -r '.token' 2>/dev/null)
    if [ -z "\$token" ] || [ "\$token" = "null" ]; then
        log "ERROR" "❌ Échec de l'authentification API"
        return 1
    fi
    log "DEBUG" "✅ Token obtenu"
    echo "\$token"
}

# Vérifier les groupes Jamf de l'utilisateur
check_jamf_user_groups() {
    local currentUser="\$1"
    local jssURL="\$2"
    local token="\$3"
    local apiuser="\$4"
    local domaine="\$5"

    if [ -z "\$token" ]; then
        token=\$(get_jamf_api_token "\$apiuser" "\$jssURL")
        [ \$? -ne 0 ] && return 1
    fi

    local userResponse
    local email="\$currentUser\$domaine"

    log "DEBUG" "URL utilisée : \$jssURL/JSSResource/users/email/\$email"
    log "DEBUG" "Token utilisé : \$token"
    log "DEBUG" "Email complet : \$email"

    userResponse=\$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer \$token" "\$jssURL/JSSResource/users/email/\$email" 2>>"\$ERROR_LOG_FILE")
    local http_code=\$(echo "\$userResponse" | tail -n1)
    userResponse=\$(echo "\$userResponse" | sed '\$d')

    if [ "\$http_code" -ne 200 ]; then
        log "ERROR" "Erreur API : Code HTTP \$http_code"
        return 1
    fi

    if [ -z "\$userResponse" ]; then
        log "ERROR" "La réponse API est vide. Consultez \$ERROR_LOG_FILE pour plus de détails."
        return 1
    else
        log "DEBUG" "Réponse API brute : \$userResponse"
    fi

    local userGroups
    userGroups=\$(echo "\$userResponse" | xmllint --xpath '/users/user/user_groups/user_group/name/text()' - 2>/dev/null | tr '\n' ' ')

    if [ -z "\$userGroups" ]; then
        log "WARNING" "⚠️ Aucun groupe trouvé pour \$email, utilisation de 'default'"
        userGroups="default"
    else
        log "DEBUG" "✅ Groupes trouvés : \$userGroups"
    fi

    echo "\$userGroups"
}

# Récupérer les applications autorisées
get_allowed_apps() {
    local plist="\$1"
    local currentUser="\$2"
    local jssURL="\$3"
    local token="\$4"
    local apiuser="\$5"
    local domaine="\$6"
    local userGroups
    userGroups=\$(check_jamf_user_groups "\$currentUser" "\$jssURL" "\$token" "\$apiuser" "\$domaine")
    [ \$? -ne 0 ] && return 1
    if [ ! -f "\$plist" ]; then
        log "ERROR" "❌ Fichier plist \$plist introuvable"
        return 1
    fi
    local allowedApps=()
    for group in \$userGroups; do
        if [ "\$group" = "Admin" ]; then
            log "DEBUG" "✅ Utilisateur dans le groupe Admin, toutes les applications sont autorisées"
            echo "ALL"  # Retourne un marqueur spécial
            return 0
        fi
        local apps
        apps=\$(plutil -extract "\$group" xml1 -o - "\$plist" 2>/dev/null | xmllint --xpath '//string/text()' - 2>/dev/null | tr '\n' ' ')
        if [ -n "\$apps" ]; then
            allowedApps+=("\$apps")
            log "DEBUG" "✅ Apps pour \$group : \$apps"
        fi
    done
    if [ \${#allowedApps[@]} -eq 0 ]; then
        local defaultApps
        defaultApps=\$(plutil -extract "appConfiguration.default" xml1 -o - "\$plist" 2>/dev/null | xmllint --xpath '//string/text()' - 2>/dev/null | tr '\n' ' ')
        if [ -n "\$defaultApps" ]; then
            allowedApps=("\$defaultApps")
            log "DEBUG" "✅ Apps par défaut : \$defaultApps"
        else
            log "ERROR" "❌ Aucune application par défaut trouvée"
            return 1
        fi
    fi
    echo "\${allowedApps[@]}"
}

# Récupérer les applications système
get_system_apps_from_plist() {
    local plist="\$1"
    if [ ! -f "\$plist" ]; then
        log "WARNING" "⚠️ Plist \$plist introuvable, liste par défaut utilisée"
        echo "com.apple.finder com.apple.dock com.apple.systemuiserver"
        return 0
    fi
    local systemApps
    systemApps=\$(plutil -extract "systemApps" xml1 -o - "\$plist" 2>/dev/null | xmllint --xpath '//string/text()' - 2>/dev/null | tr '\n' ' ')
    if [ -z "\$systemApps" ]; then
        log "WARNING" "⚠️ Clé 'systemApps' non trouvée, liste par défaut utilisée"
        echo "com.apple.finder com.apple.dock com.apple.systemuiserver"
    else
        log "DEBUG" "✅ SystemApps : \$systemApps"
        echo "\$systemApps"
    fi
}

# Fermer les applications non autorisées
close_unauthorized_apps() {
    local plist="\$1"
    local currentUser="\$2"
    local jssURL="\$3"
    local token="\$4"
    local apiuser="\$5"
    local lang="\$6"
    local domaine="\$7"
    local systemApps
    systemApps=\$(get_system_apps_from_plist "\$plist")
    local allowedApps
    allowedApps=\$(get_allowed_apps "\$plist" "\$currentUser" "\$jssURL" "\$token" "\$apiuser" "\$domaine")
    [ \$? -ne 0 ] && return 1
    
    log "DEBUG" "Liste des apps autorisé : \$allowedApps"
    if [ "\$allowedApps" = "ALL" ]; then
        log "INFO" "✅ Toutes les applications sont autorisées pour cet utilisateur"
        return 0
    fi
    log "DEBUG" "Début de la fermeture des applications"
    local runningApps
    runningApps=\$(lsappinfo list 2>/dev/null | grep 'bundleID="' | sed 's/.*bundleID="//' | sed 's/"\$//' | sort -u)
    for app in \$runningApps; do
        if [[ " \$systemApps " =~ " \$app " ]]; then
            log "DEBUG" "ℹ️ \$app est une app système, ignorée"
            continue
        fi
        if ! echo " \$allowedApps " | grep -q " \$app "; then
            log "WARNING" "⚠️ \$app non autorisée, fermeture en cours"
            local pid
            pid=\$(lsappinfo info -only pid "\$app" | sed 's/.*=\\([0-9]*\\).*/\\1/')
            if [ -n "\$pid" ]; then
                kill -15 "\$pid" 2>/dev/null
                if [ \$? -ne 0 ]; then
                    log "INFO" "⚠️ Échec de kill -15, tentative avec kill -9"
                    kill -9 "\$pid" 2>/dev/null
                fi
                notify_user "\$app" "\$currentUser" "\$lang"
            fi
        fi
    done
}

# Notifier l'utilisateur
notify_user() {
    local app="\$1"
    local currentUser="\$2"
    local lang="\$3"
    local appName
    appName=\$(lsappinfo info -only name "\$app" | sed 's/.*="//' | sed 's/"\$//' || echo "\$app")
    local title="App Watcher"
    local description
    [ "\$lang" = "fr" ] && description="L'application \$appName est non autorisée et a été fermée." || description="The application \$appName is unauthorized and has been closed."
    if [ -x "\$JAMF_HELPER" ]; then
        "\$JAMF_HELPER" -windowType utility -title "\$title" -description "\$description" -button1 "OK" -defaultButton 1
    else
        log "WARNING" "⚠️ jamfHelper non disponible"
    fi
}

# Invalider le token API
cleanup_and_invalidate_token() {
    local jssURL="\$1"
    local token="\$2"
    if [ -n "\$token" ] && [ -n "\$jssURL" ]; then
        curl -s -X POST -H "Authorization: Bearer \$token" "\$jssURL/api/v1/auth/invalidate-token" 2>>"\$ERROR_LOG_FILE"
        [ \$? -eq 0 ] && log "INFO" "✅ Token invalidé" || log "ERROR" "❌ Échec de l'invalidation du token"
    fi
}

# Exécution principale
token=\$(get_jamf_api_token "$apiuser" "$jssURL")
[ \$? -ne 0 ] && exit 1
close_unauthorized_apps "$PLIST_PATH" "$currentUser" "$jssURL" "$token" "$apiuser" "$lang" "$domaine"
cleanup_and_invalidate_token "$jssURL" "$token"
exit 0
EOF

# Appliquer les permissions au script
sudo chmod +x "$SCRIPT_PATH"
sudo chown "$currentUser:staff" "$SCRIPT_PATH"

###################################################
# Création du LaunchAgent
###################################################

cat <<EOF > "$LAUNCHAGENT_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.$company.$AppName</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$ERROR_LOG_FILE</string>
</dict>
</plist>
EOF

# Vérifier la syntaxe du LaunchAgent
if ! plutil -lint "$LAUNCHAGENT_PATH" | grep -q "OK"; then
    log "ERROR" "❌ Erreur de syntaxe dans $LAUNCHAGENT_PATH"
    exit 1
fi

# Appliquer les permissions au LaunchAgent
sudo chown "root:wheel" "$LAUNCHAGENT_PATH"
sudo chmod 644 "$LAUNCHAGENT_PATH"

# Charger le LaunchAgent pour l'utilisateur
uid=$(id -u "$currentUser")
sudo -u "$currentUser" launchctl bootout gui/"$uid" "$LAUNCHAGENT_PATH" 2>>"$ERROR_LOG_FILE"
sudo -u "$currentUser" launchctl bootstrap gui/"$uid" "$LAUNCHAGENT_PATH" 2>>"$ERROR_LOG_FILE"
if [ $? -ne 0 ]; then
    log "ERROR" "❌ Échec du chargement du LaunchAgent pour $currentUser (UID: $uid)"
    exit 1
fi

# Vérifier si le LaunchAgent est actif
launchctl_output=$(sudo -u "$currentUser" launchctl list | grep "com.$company.$AppName")
if [ -n "$launchctl_output" ]; then
    pid=$(echo "$launchctl_output" | awk '{print $1}')
    if [ "$pid" = "-" ]; then
        log "WARNING" "⚠️ LaunchAgent chargé mais pas encore actif (PID: $pid)"
    else
        log "INFO" "✅ LaunchAgent actif avec PID : $pid"
    fi
else
    log "ERROR" "❌ LaunchAgent non actif après chargement"
    exit 1
fi

log "INFO" "✅ Déploiement réussi pour $currentUser !"