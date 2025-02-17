#!/bin/bash
set -euo pipefail

apt-get update && \
	apt-get install -y libpq-dev && \
	docker-php-ext-configure pgsql -with-pgsql=/usr/local/pgsql && \
	docker-php-ext-install pdo pdo_pgsql pgsql

if [ ! -e /var/www/html/yourls-loader.php ]; then
	tar cf - --one-file-system -C /usr/src/yourls . | tar xf -
	chown -R www-data:www-data /var/www/html
fi

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ "$(id -u)" = '0' ]; then
		# if not specified, let's generate a random value
		: "${YOURLS_COOKIEKEY:=$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)}"

		# We want to copy the initial config if the actual config file doesn't already
		# exist OR if it is an empty file (e.g. it has been created for the volume mount).
		if [ ! -e /var/www/html/user/config.php ] || [ ! -s /var/www/html/user/config.php ]; then
			cp /var/www/html/user/config-docker.php /var/www/html/user/config.php
			chown www-data:www-data /var/www/html/user/config.php
		fi

		: "${YOURLS_USER:=}"
		: "${YOURLS_PASS:=}"
		if [ -n "${YOURLS_USER}" ] && [ -n "${YOURLS_PASS}" ]; then
			result=$(sed "s/  getenv_docker('YOURLS_USER') => getenv_docker('YOURLS_PASS'),/  \'${YOURLS_USER}\' => \'${YOURLS_PASS}\',/g" /var/www/html/user/config.php)
			echo "$result" > /var/www/html/user/config.php
		fi

		TERM=dumb php -- <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

require '/var/www/html/user/config.php';

list($host, $socket) = explode(':', YOURLS_DB_HOST, 2);
$port = 0;
if (is_numeric($socket)) {
	$port = (int) $socket;
	$socket = null;
}

$maxTries = 10;
do {
	$err = "";

	//FIXME: code smell, use "includes/class-<db-type>.php"; including all the dependencies and avoiding `die` calls are beyond me.  : /
	if ('mysql' === YOURLS_DB_HOST) {
		$mysql = new mysqli($host, YOURLS_DB_USER, YOURLS_DB_PASS, '', $port, $socket);
		if ($mysql->connect_error) {
			$err = "({$mysql->connect_errno}) {$mysql->connect_error}";
		}

	} else if ('pgsql' === YOURLS_DB_HOST) {
		$dbconn = pg_connect("host=" . YOURLS_DB_HOST . " dbname=" . YOURLS_DB_NAME . " user=" . YOURLS_DB_USER . " password=" . YOURLS_DB_PASS) or $err = pg_last_error();

	} else {
		fwrite($stderr, "\nUnknown database type: " . YOURLS_DB_HOST . "\n");
		die();

	}

	if ("" !== $err) {
		fwrite($stderr, "\nConnection Error: $err\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ("" !== $err);


//FIXME: code smell, use "includes/class-<db-type>.php"; including all the dependencies and avoiding `die` calls are beyond me.  : /
if ('mysql' === YOURLS_DB_HOST) {
	if (!$mysql->query('CREATE DATABASE IF NOT EXISTS '.$mysql->real_escape_string(YOURLS_DB_NAME))) {
		fwrite($stderr, "\nMySQL \"CREATE DATABASE\" Error: {$mysql->error}\n");
		$mysql->close();
		exit(1);
	}
	$mysql->close();

} else if ('pgsql' === YOURLS_DB_HOST) {
	$result = pg_query('CREATE DATABASE ' . YOURLS_DB_NAME . ' TEMPLATE template0') or die('pgsql query failed: ' . pg_last_error());
	pg_free_result($result);
	pg_close($dbconn);

}

EOPHP
	fi
fi

exec "$@"
