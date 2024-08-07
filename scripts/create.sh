#!/bin/bash -e
#
# create.sh - Delete all docker containers, build them new and install Joomla from the git branches.
#   create.sh
#   create.sh no-cache
#
# MIT License, Copyright (c) 2024 Heiko Lübbe
# https://github.com/muhme/joomla-branches-tester

ME=`basename $0`
TMP="/tmp/$ME.TMP.$$"
trap 'rm -rf $TMP' 0

source scripts/helper.sh

# Zeroth check host.docker.internal entry
HOSTS_FILE="/etc/hosts"
if grep -Eq "127.0.0.1[[:space:]]+host.docker.internal" "$HOSTS_FILE"; then
  log "Entry '127.0.0.1 host.docker.internal' exists in file '${HOSTS_FILE}' - thx :)"
else
  error "Entry '127.0.0.1 host.docker.internal' is missing in file '${HOSTS_FILE}' - try to add"
  sudo echo "127.0.0.1 host.docker.internal" >> "$HOSTS_FILE"
  if grep -Eq "127.0.0.1[[:space:]]+host.docker.internal" "$HOSTS_FILE"; then
    log "Entry '127.0.0.1 host.docker.internal' added in file '${HOSTS_FILE}'"
  else
    error "Entry '127.0.0.1 host.docker.internal' is missing in file '${HOSTS_FILE}' - please add"
    exit 1
  fi
fi

# First delete all docker containters
scripts/clean.sh

# Clean up branch directories if necessary
for version in "${VERSIONS[@]}"; do
  if [ -d "branch_${version}" ]; then
    log "Removing directory branch_${version}"
    rm -rf "branch_${version}"
  fi
done

if [ $# -eq 1 ] && [ "$1" = "no-cache" ]; then
  log "Docker compose build --no-cache"
  docker compose build --no-cache
fi

log "Docker compose up"
docker compose up -d

for version in "${VERSIONS[@]}"; do
  # If the copying has not yet been completed, then we have to wait, or we will get e.g.
  # rm: cannot remove '/var/www/html/libraries/vendor': Directory not empty.
  max_retries=120
  for ((i = 1; i < $max_retries; i++)); do
    docker logs "jbt_${version}" 2>&1 | grep 'This server is now configured to run Joomla!' && break || {
      log "Waiting for original Joomla installation, attempt ${i}/${max_retries}"
      sleep 1
    }
  done
  if [ $i -ge $max_retries ]; then
    error "Failed after $max_retries attempts, giving up"
    exit 1
  fi
  log "jbt_${version} – Deleting orignal Joomla installation"
  docker exec -it "jbt_${version}" bash -c 'rm -rf /var/www/html/* && rm -rf /var/www/html/.??*'

  # Move away the disabled PHP error logging.
  log "jbt_${version} – Show PHP warnings"
  docker exec -it "jbt_${version}" bash -c 'mv /usr/local/etc/php/conf.d/error-logging.ini /usr/local/etc/php/conf.d/error-logging.ini.DISABLED'

  log "jbt_${version} – Installing packages"
  docker exec -it "jbt_${version}" bash -c 'apt-get update -qq && \
    apt-get upgrade -y && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y git vim nodejs iputils-ping net-tools'
  # Aditional having vim, ping, netstat

  branch=$(branchName "${version}")
  log "jbt_${version} – cloning ${branch} branch into directory branch_${version}"
  docker exec -it "jbt_${version}" bash -c "git clone -b ${branch} --depth 1 https://github.com/joomla/joomla-cms /var/www/html"

  log "jbt_${version} – Composer"
  docker exec -it "jbt_${version}" bash -c "cd /var/www/html && \
    php -r \"copy('https://getcomposer.org/installer', 'composer-setup.php');\" && \
    php composer-setup.php && \
    mv composer.phar /usr/local/bin/composer && \
    composer install"

  log "jbt_${version} – npm"
  docker exec -it "jbt_${version}" bash -c 'cd /var/www/html && npm ci'

  # PR https://github.com/joomla/joomla-cms/pull/43676 – [4.4] Move the Cypress Tests to ESM
  if [ -f "branch_${version}/cypress.config.dist.js" ]; then
    extension="js"
  elif [ -f "branch_${version}/cypress.config.dist.mjs" ]; then
    extension="mjs"
  else
    error "No 'cypress.config.dist.*js' file found, please have a look" >&2
    exit 1
  fi

  log "jbt_${version} – create cypress.config.${extension}"
  # adopt e.g.:
  #   >     db_name: 'test_joomla_44'
  #   >     db_prefix: 'jos44_',
  #   >     db_host: 'host.docker.internal',
  #   >     db_port: '7011',
  #   >     baseUrl: 'http://host.docker.internal:7044',
  #   >     db_password: 'root',
  #   >     smtp_host: 'host.docker.internal',
  #   >     smtp_port: '7025',

  #     -e \"s/baseUrl: .*/baseUrl: 'http:\/\/jbt_${version}\/',/\" \
  docker exec -it "jbt_${version}" bash -c "cd /var/www/html && sed \
    -e \"s/db_name: .*/db_name: 'test_joomla_${version}',/\" \
    -e \"s/db_prefix: .*/db_prefix: 'jos${version}_',/\" \
    -e \"s/db_host: .*/db_host: 'host.docker.internal',/\" \
    -e \"s/db_port: .*/db_port: '7011',/\" \
    -e \"s/baseUrl: .*/baseUrl: 'http:\/\/host.docker.internal:70${version}\/',/\" \
    -e \"s/db_password: .*/db_password: 'root',/\" \
    -e \"s/smtp_host: .*/smtp_host: 'host.docker.internal',/\" \
    -e \"s/smtp_port: .*/smtp_port: '7025',/\" \
    cypress.config.dist.${extension} > cypress.config.${extension}"

  log "jbt_${version} – Cypress based Joomla installation"
  # temporarily disable -e for chown as on macOS seen following, but it doesn't matter as these files are 444
  #   chmod: changing permissions of '/var/www/html/.git/objects/pack/pack-b99d801ccf158bb80276c7a9cf3c15217dfaeb14.pack': Permission denied
  set +e
  # change root ownership to www-data
  docker exec -it "jbt_${version}" chown -R www-data:www-data /var/www/html >/dev/null 2>&1
  set -e
  # Joomla container needs to be restarted
  docker stop "jbt_${version}"
  docker start "jbt_${version}"

  # 'Hack' until PR with setting db_port is supported - overwrite with setting db_port in joomla-cypress and System Tests
  append="/db_host: Cypress.env('db_host'),/a\      db_port: Cypress.env('db_port'), // muhme, 9 August 2024 'hack' as long as waiting for PR"
  sed "${append}" "branch_${version}/tests/System/integration/install/Installation.cy.js" > $TMP
  cp $TMP "branch_${version}/tests/System/integration/install/Installation.cy.js"
  cp scripts/Joomla.js "branch_${version}/node_modules/joomla-cypress/src/Joomla.js"

  # 'Hack' until 6.0-dev is 

  # Using Install Joomla from System Tests
  docker exec -it jbt_cypress sh -c "cd /branch_${version} && cypress run --spec tests/System/integration/install/Installation.cy.js"

  # for the tests we need mysql user/password login
  log "jbt_${version} – Enable MySQL user root login with password"
  docker exec -it jbt_my mysql -uroot -proot -e "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';"
done

log "Aditional having vim, ping and netstat in jbt_cypress container"
docker exec -it jbt_cypress sh -c "apt-get update && apt-get install -y git vim iputils-ping net-tools"

log "Work is done, you can now use scripts/tests.sh for System Tests or scripts/patchtester.sh to install Joomla Test Patcher"
