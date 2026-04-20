<?php
require '/var/www/database/db_settings_lunch.php';

// Säkerställ att användaren är inloggad (hanterar också session-återställning)
require_once $_SERVER['DOCUMENT_ROOT'] . '/require_login.php';

$pdo=$pdo_lunch;
$print_api_token = $print_api_token ?? '';
$print_api_base_url = $print_api_base_url ?? '';

// Hämta printer_uri med prioritet: POST -> GET -> Session
$printer_uri = $_POST['printer_uri'] ?? $_GET['printer_uri'] ?? $_SESSION['printer_uri'] ?? '';
$printer_uri = trim($printer_uri);
$show_printer_setup = $printer_uri === '';

// Enkel enhetsidentifiering för att visa relevanta instruktioner
$user_agent = strtolower($_SERVER['HTTP_USER_AGENT'] ?? '');
$detected_device = 'windows';
if (strpos($user_agent, 'cros') !== false || strpos($user_agent, 'chromebook') !== false) {
    $detected_device = 'chromebook';
} elseif (strpos($user_agent, 'macintosh') !== false || strpos($user_agent, 'mac os') !== false) {
    $detected_device = 'macbook';
}

// Hämta användarinformation från databasen
$stmt = $pdo->prepare("
	SELECT bokning.users.user_givenname, bokning.users.user_email
	FROM bokning.users 
	WHERE users.user_id = :user_id
");
$stmt->execute(['user_id' => $user_id]);
$user = $stmt->fetch(PDO::FETCH_ASSOC);

// Extrahera första delen av e-postadressen (före @)
$email = $user['user_email'] ?? '';
$username = explode('@', $email)[0] ?? '';

// Hämta alla användarnamn från datorn från teg.computers tabellen
// (det kan finnas flera rader med olika computer_user-värden)
$alt_usernames = [];
$stmt = $pdo->prepare("
    SELECT DISTINCT computer_user 
    FROM teg.computers 
    WHERE google_user = :email AND computer_user IS NOT NULL AND computer_user != ''
");
$stmt->execute(['email' => $email]);
$computer_user_results = $stmt->fetchAll(PDO::FETCH_ASSOC);

foreach ($computer_user_results as $row) {
    if (!empty($row['computer_user'])) {
        $computer_user = $row['computer_user'];
        // Lägg till computer_user om det skiljer sig från username
        if ($computer_user !== $username) {
            $alt_usernames[] = $computer_user;
        }
    }
}

// Ta bort dubbletter
$alt_usernames = array_unique($alt_usernames);
// Om det bara finns ett alt_username, använd det direkt för bakåtkompatibilitet
$alt_username = !empty($alt_usernames) ? (count($alt_usernames) === 1 ? $alt_usernames[0] : null) : null;

// Kontrollera användarens gruppbehörigheter
$stmt = $pdo->prepare("
    SELECT g.group_email 
    FROM bokning.groups g 
    INNER JOIN bokning.group_users gu ON g.group_id = gu.group_id 
    WHERE gu.user_id = :user_id
");
$stmt->execute(['user_id' => $user_id]);
$user_groups = $stmt->fetchAll(PDO::FETCH_COLUMN);

// Definiera skrivare och behörigheter
$available_printers = [];
$is_medarbetare = in_array('medarbetare@tabyenskilda.se', $user_groups);
$is_fotoskrivare = in_array('fotoskrivare@tabyenskilda.se', $user_groups);
$is_printix_admin = in_array('printixadmin@tabyenskilda.se', $user_groups);
$is_printix_ekonomi = in_array('printixekonomi@tabyenskilda.se', $user_groups);
$has_rehab_email = str_ends_with(strtolower($email), '@rehab.se');
$trc_printers = [
    'ipp://xxx.xxx.xxx.xxx:631/printers/TRCBackoffice',
    'ipp://xxx.xxx.xxx.xxx:631/printers/TRCBackofficeFarg',
    'ipp://xxx.xxx.xxx.xxx:631/printers/TRCLunch'
];

if ($is_medarbetare) {
    // Medarbetare har tillgång till alla skrivare
    $available_printers = [
        'ipp://xxx.xxx.xxx.xxx:631/printers/KreativaKontoret',
        'ipp://xxx.xxx.xxx.xxx:631/printers/KunskapensHav',
        'ipp://xxx.xxx.xxx.xxx:631/printers/LaDolceVita',
        'ipp://xxx.xxx.xxx.xxx:631/printers/Ljushallen2',
        'ipp://xxx.xxx.xxx.xxx:631/printers/Ljushallen3',
        'ipp://xxx.xxx.xxx.xxx:631/printers/Platon',
        'ipp://xxx.xxx.xxx.xxx:631/printers/ReceptionTEG',
        'ipp://xxx.xxx.xxx.xxx:631/printers/Rex',
        'ipp://xxx.xxx.xxx.xxx:631/printers/SalA214',
        'ipp://xxx.xxx.xxx.xxx:631/printers/SkeppOhoj',
        'ipp://xxx.xxx.xxx.xxx:631/printers/Sokrates',
        'ipp://xxx.xxx.xxx.xxx:631/printers/WoHo',
        'ipp://xxx.xxx.xxx.xxx:631/printers/KKJonnyCash'
    ];
} elseif ($is_fotoskrivare) {
    $available_printers = [
        'ipp://xxx.xxx.xxx.xxx:631/printers/Foto',
        'ipp://xxx.xxx.xxx.xxx:631/printers/KunskapensHav',
        'ipp://xxx.xxx.xxx.xxx:631/printers/SalA214'
    ];
} else {
    // Vanliga användare har ingen behörighet
    $available_printers = [
        'ipp://xxx.xxx.xxx.xxx:631/printers/KunskapensHav',
        'ipp://xxx.xxx.xxx.xxx:631/printers/SalA214'
    ];
}

// Ge extra tillgång till TRC-skrivare för utvalda grupper och rehab-adresser
if ($is_printix_admin || $is_printix_ekonomi || $has_rehab_email) {
    $available_printers = array_values(array_unique(array_merge($available_printers, $trc_printers)));
}

// Kontrollera om användaren har behörighet till den valda skrivaren
$has_printer_access = false;
$matched_printer_uri = '';
if (!empty($printer_uri)) {
    // Sök efter matchning - antingen exakt match eller del av URI
    foreach ($available_printers as $available_printer) {
        if ($printer_uri === $available_printer || strpos($available_printer, $printer_uri) !== false) {
            $has_printer_access = true;
            $matched_printer_uri = $available_printer;
            break;
        }
    }
    if ($has_printer_access) {
        $_SESSION['printer_uri'] = $matched_printer_uri;
        $printer_uri = $matched_printer_uri; // Uppdatera för användning i API-anrop
    }
}

$print_data = null;
$http_code = 0;
$api_message = '';

// Kontrollera om det finns ett meddelande i sessionen (från redirect efter POST)
$has_session_message = false;
if (isset($_SESSION['print_message'])) {
    $api_message = $_SESSION['print_message'];
    $http_code = $_SESSION['print_message_type'] === 'success' ? 200 : 400;
    $has_session_message = true;
    // Rensa meddelandet så det inte visas igen vid nästa reload
    unset($_SESSION['print_message']);
    unset($_SESSION['print_message_type']);
}

// Hantera olika modes (endast om vi inte redan har ett sessionsmeddelande)
$mode = $_POST['mode'] ?? '';

// Kontrollera behörighet innan API-anrop
if ($has_session_message) {
    // Visa bara sessionsmeddelandet, gör ingen API-anrop
} elseif (!empty($printer_uri) && !$has_printer_access) {
    $api_message = 'Du har inte behörighet till denna skrivare. Du kan skriva ut vid "Sal A314" eller i "Kunskapens hav".';
    $http_code = 403;
} elseif ($show_printer_setup) {
    // Ingen skrivare vald: visa installationsinstruktioner istället för API-anrop
} elseif ($mode === 'release') {
    // POST-anrop till release endpoint - släpp jobb för båda användarnamnen
    $api_url = rtrim($print_api_base_url, '/') . "/release";
    
    // Släpp jobb för primärt användarnamn
    $post_data = json_encode([
        'username' => $username,
        'printer_uri' => $printer_uri
    ]);
    
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $api_url);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $post_data);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        'X-API-Token: ' . $print_api_token,
        'Content-Type: application/json'
    ]);
    $response = curl_exec($ch);
    $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    $total_released = 0;
    $release_success = false;
    
    if ($http_code === 200) {
        $response_data = json_decode($response, true);
        if ($response_data && isset($response_data['released'])) {
            $total_released += $response_data['released'];
        }
        $release_success = true;
    }
    
    // Släpp även jobb för alla alternativa användarnamn om det finns
    if (!empty($alt_usernames) && $release_success) {
        foreach ($alt_usernames as $alt_user) {
            $alt_post_data = json_encode([
                'username' => $alt_user,
                'printer_uri' => $printer_uri
            ]);
            
            $ch = curl_init();
            curl_setopt($ch, CURLOPT_URL, $api_url);
            curl_setopt($ch, CURLOPT_POST, true);
            curl_setopt($ch, CURLOPT_POSTFIELDS, $alt_post_data);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_TIMEOUT, 10);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($ch, CURLOPT_HTTPHEADER, [
                'X-API-Token: ' . $print_api_token,
                'Content-Type: application/json'
            ]);
            $alt_response = curl_exec($ch);
            $alt_http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            curl_close($ch);
            
            if ($alt_http_code === 200) {
                $alt_response_data = json_decode($alt_response, true);
                if ($alt_response_data && isset($alt_response_data['released'])) {
                    $total_released += $alt_response_data['released'];
                }
            }
        }
    }
    
    if ($release_success) {
        if ($total_released > 0) {
            $_SESSION['print_message'] = 'Jobb släppta framgångsrikt! (' . $total_released . ' jobb)<br><br><em>💡 Tips: Utskrifter med mycket bilder kan ta ett tag innan de kommer ut på skrivaren.</em>';
            $_SESSION['print_message_type'] = 'success';
        } else {
            $_SESSION['print_message'] = 'Jobb släppta framgångsrikt!<br><br><em>💡 Tips: Utskrifter med mycket bilder kan ta ett tag innan de kommer ut på skrivaren.</em>';
            $_SESSION['print_message_type'] = 'success';
        }
        // Redirect för att förhindra omskickning av formulär vid omladdning
        header('Location: /print/index.php?printer_uri=' . urlencode($printer_uri));
        exit;
    } else {
        $api_message = 'Fel vid släpp av jobb. HTTP-kod: ' . $http_code;
    }
    
} elseif ($mode === 'cleanup') {
    // POST-anrop till cleanup endpoint
    $api_url = rtrim($print_api_base_url, '/') . "/cleanup";
    $job_id = $_POST['job_id'] ?? null;
    
    // Säkerhetsvalidering - kontrollera att cleanup_username är giltig för denna användare
    $cleanup_username = $_POST['cleanup_username'] ?? $username;
    $valid_usernames = [$username];
    if (!empty($alt_usernames)) {
        $valid_usernames = array_merge($valid_usernames, $alt_usernames);
    }
    
    // Om cleanup_username inte är giltig, använd standardanvändarnamnet
    if (!in_array($cleanup_username, $valid_usernames)) {
        $cleanup_username = $username;
    }
    
    if ($job_id) {
        // Ta bort specifikt jobb
        $post_data = json_encode([
            'username' => $cleanup_username,
            'printer_uri' => $printer_uri,
            'job_id' => $job_id
        ]);
    } else {
        // Töm hela kön för båda användarnamnen
        $post_data = json_encode([
            'username' => $username,
            'printer_uri' => $printer_uri
        ]);
    }
    
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $api_url);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $post_data);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        'X-API-Token: ' . $print_api_token,
        'Content-Type: application/json'
    ]);
    $response = curl_exec($ch);
    $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    $total_cleaned = 0;
    $cleanup_success = false;
    
    if ($http_code === 200) {
        $response_data = json_decode($response, true);
        if ($response_data && isset($response_data['cleaned'])) {
            $total_cleaned += $response_data['cleaned'];
        }
        $cleanup_success = true;
    }
    
    // Om det är fullständig rensning (inte specifikt jobb) och vi har alternativa användarnamn
    if (!$job_id && !empty($alt_usernames) && $cleanup_success) {
        foreach ($alt_usernames as $alt_user) {
            $alt_post_data = json_encode([
                'username' => $alt_user,
                'printer_uri' => $printer_uri
            ]);
            
            $ch = curl_init();
            curl_setopt($ch, CURLOPT_URL, $api_url);
            curl_setopt($ch, CURLOPT_POST, true);
            curl_setopt($ch, CURLOPT_POSTFIELDS, $alt_post_data);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_TIMEOUT, 10);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($ch, CURLOPT_HTTPHEADER, [
                'X-API-Token: ' . $print_api_token,
                'Content-Type: application/json'
            ]);
            $alt_response = curl_exec($ch);
            $alt_http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            curl_close($ch);
            
            if ($alt_http_code === 200) {
                $alt_response_data = json_decode($alt_response, true);
                if ($alt_response_data && isset($alt_response_data['cleaned'])) {
                    $total_cleaned += $alt_response_data['cleaned'];
                }
            }
        }
    }
    
    if ($cleanup_success) {
        if ($job_id) {
            $_SESSION['print_message'] = 'Jobb borttaget framgångsrikt!';
            $_SESSION['print_message_type'] = 'success';
        } else {
            if ($total_cleaned > 0) {
                $_SESSION['print_message'] = 'Skrivutningskö rensad framgångsrikt! (' . $total_cleaned . ' jobb rensade)';
                $_SESSION['print_message_type'] = 'success';
            } else {
                $_SESSION['print_message'] = 'Skrivutningskö rensad framgångsrikt!';
                $_SESSION['print_message_type'] = 'success';
            }
        }
        // Redirect för att förhindra omskickning av formulär vid omladdning
        header('Location: /print/index.php?printer_uri=' . urlencode($printer_uri));
        exit;
    } else {
        $api_message = $job_id ? 'Fel vid borttagning av jobb. HTTP-kod: ' . $http_code : 'Fel vid rensning av kö. HTTP-kod: ' . $http_code;
    }
    
    } else {
        // Default: Hämta lista med jobb
        if (!empty($printer_uri) && !$has_printer_access) {
            $api_message = 'Du har inte behörighet till denna skrivare. Du kan skriva ut vid "Sal A314" eller i "Kunskapens hav".';
            $http_code = 403;
        } else {
            // Hämta jobb för primärt användarnamn
            $api_url = rtrim($print_api_base_url, '/') . "/list?username=" . urlencode($username);
            if (!empty($printer_uri)) {
                $api_url .= "&printer_uri=" . urlencode($printer_uri);
            }

            $ch = curl_init();
            curl_setopt($ch, CURLOPT_URL, $api_url);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_TIMEOUT, 10);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($ch, CURLOPT_HTTPHEADER, [
                'X-API-Token: ' . $print_api_token
            ]);
            $response = curl_exec($ch);
            $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            curl_close($ch);
            
            $print_data = null;
            $alt_print_data = null;
            
            if ($http_code === 200 && $response) {
                $print_data = json_decode($response, true);
                // Lägg till användarnamn för varje jobb
                if (isset($print_data['jobs']) && is_array($print_data['jobs'])) {
                    foreach ($print_data['jobs'] as &$job) {
                        $job['source_username'] = $username;
                    }
                }
            }
            
            // Hämta jobb för alla alternativa användarnamn (kan finnas flera datorer med olika computer_user)
            foreach ($alt_usernames as $alt_user) {
                if ($alt_user !== $username) {
                    $alt_api_url = rtrim($print_api_base_url, '/') . "/list?username=" . urlencode($alt_user);
                    if (!empty($printer_uri)) {
                        $alt_api_url .= "&printer_uri=" . urlencode($printer_uri);
                    }

                    $ch = curl_init();
                    curl_setopt($ch, CURLOPT_URL, $alt_api_url);
                    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
                    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
                    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
                    curl_setopt($ch, CURLOPT_HTTPHEADER, [
                        'X-API-Token: ' . $print_api_token
                    ]);
                    $alt_response = curl_exec($ch);
                    $alt_http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
                    curl_close($ch);
                    
                    if ($alt_http_code === 200 && $alt_response) {
                        $alt_print_data = json_decode($alt_response, true);
                        // Lägg till användarnamn för varje jobb
                        if (isset($alt_print_data['jobs']) && is_array($alt_print_data['jobs'])) {
                            foreach ($alt_print_data['jobs'] as &$job) {
                                $job['source_username'] = $alt_user;
                            }
                        }
                        
                        // Kombinera jobblistorna
                        if ($print_data && isset($print_data['jobs']) && isset($alt_print_data['jobs'])) {
                            $print_data['jobs'] = array_merge($print_data['jobs'], $alt_print_data['jobs']);
                        } elseif (!$print_data && $alt_print_data) {
                            $print_data = $alt_print_data;
                        }
                    }
                }
            }
        }
    }
?>

<!DOCTYPE html>
<html lang="sv">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>Print</title>
	<style>
		body {
			font-family: Raleway, sans-serif;
			margin: 0;
			padding: 10px;
			background-color: #f4f4f4;
			display: flex;
			flex-direction: column;
			align-items: center;
			justify-content: center;
			min-height: 100vh;
			box-sizing: border-box;
		}
		.header-image {
			margin-bottom: 20px;
		}
		.card {
			background-color: #ffffff;
			border-radius: 10px;
			box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
			padding: 20px;
			width: 400px;
			max-width: calc(100vw - 20px);
			text-align: center;
			border: 1px solid #ccc;
			box-sizing: border-box;
		}
		.card h1 {
			font-size: 1.5em;
			margin-bottom: 10px;
		}
		.card p {
			margin: 5px 0;
			font-size: 1.1em;
		}

		.header-image {
			-webkit-filter: invert(100%); /* safari 6.0 - 9.0 */
			filter: invert(100%);
			border:0;
		}
		.error {
			color: #dc3545;
			font-weight: bold;
		}
		.success {
			color: #28a745;
			font-weight: bold;
		}
		.job-item {
			background-color: #f8f9fa;
			border: 1px solid #dee2e6;
			border-radius: 5px;
			padding: 15px;
			margin: 10px 0;
			text-align: left;
		}
		.job-title {
			font-weight: bold;
			font-size: 1.1em;
			margin-bottom: 8px;
		}
		.job-details {
			font-size: 0.9em;
			color: #666;
		}
		.button-group {
			margin-top: 20px;
			display: flex;
			gap: 10px;
			justify-content: center;
			flex-wrap: wrap;
		}
		.btn {
			padding: 10px 20px;
			border: none;
			border-radius: 5px;
			cursor: pointer;
			font-size: 1em;
			text-decoration: none;
			display: inline-block;
		}
		.btn-primary {
			background-color: #28a745;
			color: white;
		}
		.btn-primary:hover {
			background-color: #218838;
		}
		.btn-secondary {
			background-color: #6c757d;
			color: white;
		}
		.btn-secondary:hover {
			background-color: #5a6268;
		}
		.btn-danger {
			background-color: #dc3545;
			color: white;
		}
		.btn-danger:hover {
			background-color: #c82333;
		}
		form {
			display: inline;
		}
		.hidden {
			display: none;
		}
		.debug-link {
			display: block;
			margin-top: 20px;
			color: #6c757d;
			text-decoration: none;
			font-size: 0.8em;
			text-align: center;
			cursor: pointer;
			transition: color 0.2s;
		}
		.debug-link:hover {
			color: #495057;
			text-decoration: underline;
		}
		.debug-section {
			background-color: #f8f9fa;
			border: 1px solid #dee2e6;
			border-radius: 5px;
			padding: 15px;
			margin-top: 15px;
			text-align: left;
			font-size: 0.9em;
		}
        .debug-section h4 {
			margin-top: 0;
			color: #495057;
			font-size: 1.1em;
		}
		.debug-section p {
			margin: 5px 0;
			font-family: monospace;
			word-break: break-all;
		}
		.setup-box {
			background-color: #f8f9fa;
			border: 1px solid #dee2e6;
			border-radius: 8px;
			padding: 15px;
			margin-top: 15px;
			text-align: left;
		}
		.setup-box h3, .setup-box h4 {
			margin-top: 0;
		}
		.setup-box ul {
			padding-left: 20px;
			margin: 8px 0;
		}
		.setup-box li {
			margin-bottom: 5px;
		}
		.highlight-device {
			border: 2px solid #28a745;
			background-color: #f1fff4;
		}
		.uri-list {
			margin-top: 10px;
			font-family: monospace;
			font-size: 0.9em;
			word-break: break-all;
		}
		.uri-list li {
			margin-bottom: 8px;
		}
		.uri-link {
			font-family: inherit;
			font-size: inherit;
			color: #1a73e8;
			text-decoration: underline;
		}
	</style>
</head>
<body>
	<a href="/login.php"><img class="header-image is-logo-image" alt="Täby Enskilda Gymnasium" src="/teg_logo.svg" title="Täby Enskilda Gymnasium" width="200"></a>

	<div class="card">
		<h1>Print - <?php echo htmlspecialchars($user['user_givenname']); ?></h1>
		
		<?php if ($api_message): ?>
			<p class="<?php echo $http_code === 200 ? 'success' : 'error'; ?>"><?php echo $api_message; ?></p>
			<?php if (isset($show_back_button) && $show_back_button): ?>
				<div class="button-group">
					<form method="get">
						<input type="hidden" name="printer_uri" value="<?php echo htmlspecialchars($printer_uri); ?>">
						<button type="submit" class="btn btn-primary">Tillbaka till utskriftskö</button>
					</form>
				</div>
			<?php endif; ?>
		<?php endif; ?>
		
		<?php if (empty($available_printers)): ?>
			<p class="error">Du har inte behörighet till några skrivare. Du kan skriva ut vid "Sal A214" eller i "Kunskapens hav".</p>
		<?php endif; ?>
		
		<?php if ($show_printer_setup): ?>
			<div class="setup-box">
				<h3>Lägg till skrivare</h3>
				<p>Ingen skrivare är vald ännu. För att lägga till en skrivare följ instruktionerna nedan.</p>
			</div>

			<?php if ($detected_device === 'chromebook'): ?>
			<div class="setup-box highlight-device">
				<h4>Chromebook (ChromeOS)</h4>
				<ul>
					<li>Öppna <strong>Inställningar</strong> och gå till <strong>Enhet</strong> → <strong>Skrivare och skannrar</strong>.</li>
					<li>Välj <strong>Lägg till skrivare manuellt</strong>.</li>
					<li>Ange:
						<ul>
							<li><strong>Adress:</strong> <code>xxx.xxx.xxx.xxx</code></li>
							<li><strong>Protokoll:</strong> <code>IPP</code></li>
							<li><strong>Kö:</strong> <code>printers/SKRIVARNAMN</code> (t.ex. <code>printers/KunskapensHav</code>)</li>
						</ul>
					</li>
					<li>Spara skrivaren och skriv ut som vanligt.</li>
				</ul>
			</div>
			<?php endif; ?>

			<?php if ($detected_device === 'macbook'): ?>
			<div class="setup-box highlight-device">
				<h4>MacBook (macOS)</h4>
				<ul>
					<li>Öppna appen <strong>Managed Software Center</strong>.</li>
					<li>Välj kategorin <strong>Print</strong>.</li>
					<li>Installera den skrivare du vill ha.</li>
				</ul>
			</div>
			<?php endif; ?>

			<?php if ($detected_device === 'windows'): ?>
			<div class="setup-box highlight-device">
				<h4>Windows (Windows 11)</h4>
				<ul>
					<li>Öppna <strong>Inställningar</strong> → <strong>Bluetooth och enheter</strong> → <strong>Skrivare och skannrar</strong>.</li>
					<li>Välj <strong>Lägg till enhet</strong> och sedan <strong>Lägg till manuellt</strong>.</li>
					<li>Välj <strong>Välj en delad skrivare efter namn</strong>.</li>
					<li>Ange skrivarens URL enligt formatet:
						<ul>
							<li><code>ipp://xxx.xxx.xxx.xxx:631/printers/SKRIVARNAMN</code></li>
						</ul>
					</li>
				</ul>
			</div>
			<?php endif; ?>

			<div class="setup-box">
				<h4>Tillgängliga skrivare</h4>
				<?php if (!empty($available_printers)): ?>
					<ul class="uri-list">
						<?php foreach ($available_printers as $printer): ?>
							<?php $printer_name_for_link = basename($printer); ?>
							<li>
								<strong><?php echo htmlspecialchars($printer_name_for_link); ?></strong><br>
								<code><?php echo htmlspecialchars($printer); ?></code>
							</li>
						<?php endforeach; ?>
					</ul>
				<?php else: ?>
					<p class="error">Du har inte behörighet till några skrivare. Kontakta administrationen om du behöver åtkomst.</p>
				<?php endif; ?>
			</div>
		<?php elseif ($print_data): ?>
			<?php if (isset($print_data['printer_uri'])): ?>
				<?php 
				$printer_name = $print_data['printer_uri'];
				// Extrahera sista delen av printer-URI:n (efter sista /)
				if (strpos($printer_name, '/') !== false) {
					$printer_name = basename($printer_name);
				}
				?>
				<p><strong>Printer:</strong> <?php echo htmlspecialchars($printer_name); ?></p>
			<?php endif; ?>
			
			<?php if (isset($print_data['jobs']) && is_array($print_data['jobs'])): ?>
				<h3>Utskriftsjobb (<?php echo count($print_data['jobs']); ?>)</h3>
				<?php foreach ($print_data['jobs'] as $job): ?>
					<div class="job-item">
						<div class="job-title"><?php echo htmlspecialchars($job['title'] ?? 'Namnlöst jobb'); ?></div>
						<div class="job-details">
							<strong>Sidor:</strong> <?php echo htmlspecialchars($job['pages'] ?? '0'); ?><br>
							<strong>Skickat:</strong> <?php echo isset($job['submitted']) ? date('Y-m-d H:i:s', $job['submitted']) : 'N/A'; ?><br>
							<?php if (isset($job['source_username']) && $job['source_username'] !== $username): ?>
								<strong>Användarnamn:</strong> <?php echo htmlspecialchars($job['source_username']); ?>
							<?php endif; ?>
						</div>
						<form method="post" style="display: inline; margin-left: 10px;">
							<input type="hidden" name="mode" value="cleanup">
							<input type="hidden" name="printer_uri" value="<?php echo htmlspecialchars($printer_uri); ?>">
							<input type="hidden" name="job_id" value="<?php echo htmlspecialchars($job['jobid'] ?? ''); ?>">
							<input type="hidden" name="cleanup_username" value="<?php echo htmlspecialchars($job['source_username'] ?? $username); ?>">
							<button type="submit" style="background: none; border: none; cursor: pointer; font-size: 1.2em; padding: 0; margin: 0;" title="Ta bort jobb">🗑️</button>
						</form>
					</div>
				<?php endforeach; ?>
				<?php if (count($print_data['jobs']) > 0): ?>
					<div class="button-group">
						<form method="post">
							<input type="hidden" name="mode" value="release">
							<input type="hidden" name="printer_uri" value="<?php echo htmlspecialchars($printer_uri); ?>">
							<button type="submit" class="btn btn-primary">Skriv ut</button>
						</form>
						<form method="post">
							<input type="hidden" name="mode" value="cleanup">
							<input type="hidden" name="printer_uri" value="<?php echo htmlspecialchars($printer_uri); ?>">
							<button type="submit" class="btn btn-secondary">Töm listan</button>
						</form>
					</div>
				<?php endif; ?>
			<?php endif; ?>
			
			<?php if (isset($print_data['jobs']) && is_array($print_data['jobs']) && count($print_data['jobs']) === 0): ?>
				<p style="margin-top: 20px; color: #666; font-size: 0.9em;">
					💡 <strong>Tips:</strong> <a href="https://docs.google.com/document/d/1m9d8kdzfm9gLW60Lt_Wnf09BAKbkx0l53YSXhtn10YE/edit?usp=sharing" target="_blank" style="color: #666; text-decoration: underline;">Behöver du hjälp med att lägga till en skrivare?</a>
				</p>
			<?php endif; ?>
		<?php elseif (!$api_message): ?>
			<p class="error">Kunde inte hämta utkriftskö.</p>
			<p><strong>Användarnamn:</strong> <?php echo htmlspecialchars($username); ?></p>
			<p><strong>HTTP-kod:</strong> <?php echo $http_code; ?></p>
		<?php endif; ?>
		
		<div style="margin-top: 20px;">
			<a href="/login.php" class="btn btn-secondary">Tillbaka till huvudmenyn</a>
		</div>
	</div>
	
	<!-- Debug-länk -->
	<a href="#" onclick="toggleDebug()" class="debug-link">Debug-information till Tomas</a>
	
	<!-- Debug-sektion -->
	<div id="debug-section" class="debug-section hidden">
		<h4>Debug-information</h4>
		<p><strong>E-post:</strong> <?php echo htmlspecialchars($user['user_email'] ?? 'N/A'); ?></p>
		<p><strong>Användarnamn:</strong> <?php echo htmlspecialchars($username); ?></p>
		<?php if ($alt_username): ?>
			<p><strong>Alternativt användarnamn:</strong> <?php echo htmlspecialchars($alt_username); ?></p>
		<?php endif; ?>
		<p><strong>Printer URI:</strong> <?php echo htmlspecialchars($printer_uri ?: 'Ingen vald'); ?></p>
		<?php if (isset($print_data['jobs']) && is_array($print_data['jobs'])): ?>
			<p><strong>Jobb-ID:n:</strong> <?php echo implode(', ', array_map(function($job) { return $job['jobid'] ?? 'N/A'; }, $print_data['jobs'])); ?></p>
		<?php else: ?>
			<p><strong>Jobb-ID:n:</strong> Inga jobb</p>
		<?php endif; ?>
		<p><strong>Grupper:</strong></p>
		<ul style="margin: 5px 0; padding-left: 20px;">
			<?php if (!empty($user_groups)): ?>
				<?php foreach ($user_groups as $group): ?>
					<li><?php echo htmlspecialchars($group); ?></li>
				<?php endforeach; ?>
			<?php else: ?>
				<li>Inga grupper</li>
			<?php endif; ?>
		</ul>
		<p><strong>Tillgängliga skrivare:</strong></p>
		<ul style="margin: 5px 0; padding-left: 20px;">
			<?php if (!empty($available_printers)): ?>
				<?php foreach ($available_printers as $printer): ?>
					<li><?php echo htmlspecialchars($printer); ?></li>
				<?php endforeach; ?>
			<?php else: ?>
				<li>Inga skrivare</li>
			<?php endif; ?>
		</ul>
	</div>
	
	<?php if ($mode === 'release' && $http_code === 200): ?>
	<script>
		setTimeout(function() {
			// Visa meddelande om att stänga fönstret
			var closeMessage = document.createElement('div');
			closeMessage.innerHTML = '<p style="margin-top: 20px; color: #666; font-size: 0.9em;">Du kan nu stänga detta fönster</p>';
			document.querySelector('.card').appendChild(closeMessage);
		}, 3000);
	</script>
	<?php endif; ?>
	
	<script>
		function toggleDebug() {
			var debugSection = document.getElementById('debug-section');
			if (debugSection.classList.contains('hidden')) {
				debugSection.classList.remove('hidden');
			} else {
				debugSection.classList.add('hidden');
			}
		}
	</script>
</body>
</html> 
