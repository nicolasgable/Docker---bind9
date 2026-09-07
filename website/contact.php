<?php
declare(strict_types=1);

require __DIR__ . '/lib/PHPMailer/Exception.php';
require __DIR__ . '/lib/PHPMailer/PHPMailer.php';
require __DIR__ . '/lib/PHPMailer/SMTP.php';

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception as PHPMailerException;

header('Content-Type: application/json; charset=utf-8');

function respond(bool $success, string $message, int $status = 200): void
{
    http_response_code($status);
    echo json_encode(['success' => $success, 'message' => $message]);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    respond(false, 'Méthode non autorisée.', 405);
}

$configFile = __DIR__ . '/config.php';
if (!file_exists($configFile)) {
    respond(false, "Le formulaire n'est pas encore configuré (config.php manquant).", 500);
}
$config = require $configFile;

// Honeypot anti-spam : champ caché qui ne doit jamais être rempli par un humain
if (!empty($_POST['website'] ?? '')) {
    respond(true, 'Message envoyé, merci !');
}

$name    = trim((string) ($_POST['name'] ?? ''));
$email   = trim((string) ($_POST['email'] ?? ''));
$subject = trim((string) ($_POST['subject'] ?? ''));
$message = trim((string) ($_POST['message'] ?? ''));

if ($name === '' || $email === '' || $message === '') {
    respond(false, 'Merci de renseigner votre nom, votre email et votre message.', 422);
}

if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    respond(false, "L'adresse email saisie n'est pas valide.", 422);
}

if (mb_strlen($name) > 150 || mb_strlen($subject) > 200 || mb_strlen($message) > 5000) {
    respond(false, 'Un des champs dépasse la longueur autorisée.', 422);
}

$mail = new PHPMailer(true);

try {
    $mail->isSMTP();
    $mail->Host       = $config['smtp_host'];
    $mail->Port       = $config['smtp_port'];
    $mail->SMTPAuth   = true;
    $mail->Username   = $config['smtp_username'];
    $mail->Password   = $config['smtp_password'];
    $mail->SMTPSecure = $config['smtp_secure'];
    $mail->CharSet    = 'UTF-8';

    $mail->setFrom($config['from_email'], $config['from_name']);
    $mail->addAddress($config['to_email'], $config['to_name'] ?? '');
    $mail->addReplyTo($email, $name);

    $mail->Subject = $subject !== ''
        ? sprintf('[Site AllSafe] %s', $subject)
        : sprintf('[Site AllSafe] Nouveau message de %s', $name);

    $mail->isHTML(false);
    $mail->Body = "Nouveau message depuis le formulaire de contact allsafe.ovh\n\n"
        . "Nom : {$name}\n"
        . "Email : {$email}\n\n"
        . "Message :\n{$message}\n";

    $mail->send();

    respond(true, 'Votre message a bien été envoyé, merci ! Je vous répondrai rapidement.');
} catch (PHPMailerException $e) {
    error_log('Contact form mail error: ' . $mail->ErrorInfo);
    respond(false, "Une erreur est survenue lors de l'envoi. Merci de réessayer plus tard ou de m'écrire directement à nicolas@allsafe.ovh.", 500);
}
