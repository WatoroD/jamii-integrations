# Jamii MI runtime for the local/CI target environment.
# The CAR is NOT baked in here: the pipeline hot-deploys it into the mounted carbonapps
# directory so the same image can be redeployed/rolled back quickly in dev.
# (For prod the recommended pattern is an immutable image per release: COPY the CAR in
#  a final stage - see README "Pipeline".)
ARG MI_VERSION=4.4.0
FROM wso2/wso2mi:${MI_VERSION}

ARG MI_VERSION=4.4.0
ARG MYSQL_DRIVER_VERSION=8.4.0
ENV MI_HOME=/home/wso2carbon/wso2mi-${MI_VERSION}

# JDBC driver for the data service
ADD --chown=wso2carbon:wso2 \
    https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_DRIVER_VERSION}/mysql-connector-j-${MYSQL_DRIVER_VERSION}.jar \
    ${MI_HOME}/lib/

# Trust public CAs for outbound HTTPS (DummyJSON sits behind a public CDN certificate).
RUN keytool -importkeystore -noprompt \
      -srckeystore "${JAVA_HOME}/lib/security/cacerts" -srcstorepass changeit \
      -destkeystore "${MI_HOME}/repository/resources/security/client-truststore.jks" -deststorepass wso2carbon \
    || echo "WARN: cacerts import failed; outbound TLS to public endpoints may fail"

# Endpoint timeouts are enforced by a periodic sweep (default every 15 s), so a "3 s" timeout
# could take up to 18 s to fire. Sweep every second so the configured timeouts mean what they say.
RUN printf '\n[synapse_properties]\n"synapse.timeout_handler_interval" = "1000"\n' >> "${MI_HOME}/conf/deployment.toml"
