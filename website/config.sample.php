<?php
// Copiez ce fichier en "config.php" (ne pas committer config.php : il contient
// vos identifiants) et renseignez vos paramètres SMTP réels.

return [
    // Serveur SMTP de votre hébergeur / fournisseur mail (ex: OVH: ssl0.ovh.net)
    'smtp_host' => 'ssl0.ovh.net',

    // Port SMTP : 465 (SSL/TLS implicite) ou 587 (STARTTLS)
    'smtp_port' => 465,

    // Type de chiffrement : 'ssl' (port 465) ou 'tls' (port 587)
    'smtp_secure' => 'ssl',

    // Identifiants du compte mail utilisé pour l'envoi
    'smtp_username' => 'nicolas@allsafe.ovh',
    'smtp_password' => 'CHANGEZ-MOI',

    // Adresse et nom affichés comme expéditeur (souvent identiques au compte SMTP)
    'from_email' => 'nicolas@allsafe.ovh',
    'from_name'  => 'Site AllSafe',

    // Adresse(s) qui recevront les messages du formulaire de contact
    'to_email' => 'nicolas@allsafe.ovh',
    'to_name'  => 'AllSafe',
];
