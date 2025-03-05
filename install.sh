#!/bin/bash

# install.sh - Script d'installation pour app_watcher

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root. Utilisez sudo."
    exit 1
fi

# Vérifier l'existence des fichiers sources
if [ ! -f "scripts/app_watcher.sh" ]; then
    echo "Erreur : scripts/app_watcher.sh introuvable"
    exit 1
fi
if [ ! -f "config/jamf.conf" ]; then
    echo "Erreur : config/jamf.conf introuvable"
    exit 1
fi
if [ ! -f "config/apps.plist" ]; then
    echo "Erreur : config/apps.plist introuvable"
    exit 1
fi

# Créer les répertoires nécessaires
mkdir -p /usr/local/bin /etc /var/log

# Copier le script principal
cp scripts/app_watcher.sh /usr/local/bin/
chmod 700 /usr/local/bin/app_watcher.sh
chown root:admin /usr/local/bin/app_watcher.sh

# Copier les fichiers de configuration
cp config/jamf.conf /etc/
chmod 600 /etc/jamf.conf
chown root:admin /etc/jamf.conf

cp config/apps.plist /etc/
chmod 644 /etc/apps.plist
chown root:admin /etc/apps.plist

# Créer le fichier de log
touch /var/log/app_watcher.log
chmod 644 /var/log/app_watcher.log
chown root:admin /var/log/app_watcher.log

# Vérifier les dépendances
if ! command -v jq >/dev/null 2>&1; then
    echo "Avertissement : 'jq' n'est pas installé. Installez-le avec 'brew install jq'."
fi
if ! command -v xmllint >/dev/null 2>&1; then
    echo "Avertissement : 'xmllint' n'est pas installé. Installez-le avec 'brew install libxml2'."
fi

# Copier et charger le LaunchDaemon (optionnel, si fourni)
if [ -f "config/com.example.appwatcher.plist" ]; then
    cp config/com.example.appwatcher.plist /Library/LaunchDaemons/
    chmod 644 /Library/LaunchDaemons/com.example.appwatcher.plist
    chown root:wheel /Library/LaunchDaemons/com.example.appwatcher.plist
    launchctl load /Library/LaunchDaemons/com.example.appwatcher.plist
fi

echo "Installation terminée. Configurez /etc/jamf.conf avec vos identifiants et /etc/apps.plist avec les applications autorisées."