SERVICE_NAME=ceilometer
SERVICE_PASS=${CEILOMETER_PASS}
SERVICE_EMAIL=ceilometer@localhost
SERVICE_TYPE=metering
SERVICE_DESCRIPTION="Telemetry Service"
SERVICE_URL_PUBLIC=http://${CONTROLLER_HOSTNAME}:8777
SERVICE_URL_INTERNAL=http://${CONTROLLER_HOSTNAME}:8777
SERVICE_URL_ADMIN=http://${CONTROLLER_HOSTNAME}:8777