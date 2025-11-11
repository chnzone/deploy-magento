#!/bin/bash

# Start the cron
cron start

# Exec. default command (php-fpm)
exec "$@"
