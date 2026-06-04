/*
 * Copyright Debezium Authors.
 *
 * Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
 */
package io.debezium.examples.embedded;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.Types;
import java.util.Properties;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.debezium.engine.format.Json;

/**
 * Kafka-free CockroachDB-to-CockroachDB replication.
 *
 * <p>Runs the Debezium CockroachDB connector in <b>sinkless</b> mode inside the Debezium
 * <b>embedded engine</b>. There is no Kafka and no Kafka Connect: the changefeed streams over the
 * source SQL connection, the embedded engine hands each change to this process, and the consumer
 * applies it to the target CockroachDB over JDBC. Offsets (the changefeed cursor) are stored in
 * CockroachDB itself via {@link CockroachDBOffsetBackingStore}.</p>
 *
 * <p>Replicates a single table ({@code orders(id, name, amount)}) to keep the apply logic small and
 * readable; the same pattern extends to more tables.</p>
 */
public final class EmbeddedSinklessReplicator {

    private static final Logger LOGGER = LoggerFactory.getLogger(EmbeddedSinklessReplicator.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private EmbeddedSinklessReplicator() {
    }

    public static void main(String[] args) throws Exception {
        String sourceHost = env("SOURCE_HOST", "localhost");
        String sourcePort = env("SOURCE_PORT", "26257");
        String targetHost = env("TARGET_HOST", "localhost");
        String targetPort = env("TARGET_PORT", "26258");
        String user = env("CRDB_USER", "root");

        String targetUrl = "jdbc:postgresql://" + targetHost + ":" + targetPort + "/targetdb?sslmode=disable";
        Connection target = DriverManager.getConnection(targetUrl, user, "");
        target.setAutoCommit(true);
        LOGGER.info("Connected to target CockroachDB at {}:{}/targetdb", targetHost, targetPort);

        Properties props = new Properties();
        props.setProperty("name", "crdb-embedded-sinkless");
        props.setProperty("connector.class", "io.debezium.connector.cockroachdb.CockroachDBConnector");

        // No Kafka, no Kafka Connect: the connector cursor is checkpointed into CockroachDB itself
        // (a debezium_offsets table on the target) by the self-contained CockroachDBOffsetBackingStore.
        // No loose state file, no Kafka, no extra Debezium storage artifact.
        props.setProperty("offset.storage", "io.debezium.examples.embedded.CockroachDBOffsetBackingStore");
        props.setProperty("offset.storage.crdb.url", targetUrl);
        props.setProperty("offset.storage.crdb.user", user);
        props.setProperty("offset.storage.crdb.password", "");
        props.setProperty("offset.storage.crdb.table", "debezium_offsets");
        props.setProperty("offset.flush.interval.ms", "1000");

        // Source CockroachDB.
        props.setProperty("database.hostname", sourceHost);
        props.setProperty("database.port", sourcePort);
        props.setProperty("database.user", user);
        props.setProperty("database.password", "");
        props.setProperty("database.dbname", "demodb");
        props.setProperty("database.sslmode", "disable");
        props.setProperty("database.server.name", "embedded");
        props.setProperty("topic.prefix", "embedded");
        props.setProperty("table.include.list", "public.orders");

        // Sinkless source: CockroachDB never connects to Kafka either.
        props.setProperty("cockroachdb.changefeed.sink.type", "sinkless");
        props.setProperty("cockroachdb.changefeed.include.diff", "true");
        props.setProperty("cockroachdb.changefeed.resolved.interval", "5s");
        props.setProperty("snapshot.mode", "initial");

        // Plain JSON envelopes (no schema wrapper) so the consumer can read after/before directly.
        props.setProperty("value.converter.schemas.enable", "false");
        props.setProperty("key.converter.schemas.enable", "false");

        CountDownLatch stopped = new CountDownLatch(1);
        DebeziumEngine<ChangeEvent<String, String>> engine = DebeziumEngine.create(Json.class)
                .using(props)
                .notifying((ChangeEvent<String, String> record) -> applyToTarget(target, record))
                .build();

        ExecutorService executor = Executors.newSingleThreadExecutor();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOGGER.info("Shutting down embedded engine...");
            try {
                engine.close();
                executor.shutdown();
                executor.awaitTermination(10, TimeUnit.SECONDS);
                target.close();
            }
            catch (Exception e) {
                LOGGER.warn("Error during shutdown: {}", e.getMessage());
            }
            stopped.countDown();
        }));

        LOGGER.info("Starting embedded engine (sinkless source, no Kafka, no Kafka Connect)...");
        executor.execute(engine);
        stopped.await();
    }

    /**
     * Applies one change event to the target. Inserts/updates/reads upsert the row; deletes remove
     * it; tombstones (null value) and resolved/heartbeat records are ignored. The primary key is read
     * from the record key, which is always present, rather than from {@code before}/{@code after}.
     */
    private static void applyToTarget(Connection target, ChangeEvent<String, String> record) {
        String value = record.value();
        if (value == null || value.isBlank()) {
            return; // tombstone (the null-value record Debezium emits after a delete)
        }
        try {
            JsonNode envelope = MAPPER.readTree(value);
            String op = envelope.path("op").asText("");
            if (op.isEmpty()) {
                return; // not a data change event (e.g. resolved/heartbeat)
            }
            Long id = resolveId(record.key(), envelope);
            if (id == null) {
                LOGGER.warn("Skipping event with no resolvable id: {}", value);
                return;
            }
            if ("d".equals(op)) {
                try (PreparedStatement ps = target.prepareStatement("DELETE FROM orders WHERE id = ?")) {
                    ps.setLong(1, id);
                    ps.executeUpdate();
                }
                LOGGER.info("apply op=d  id={}", id);
                return;
            }
            // c, u, r -> upsert
            JsonNode after = envelope.path("after");
            if (after.isMissingNode() || after.isNull()) {
                return;
            }
            String name = after.path("name").asText(null);
            String amount = after.path("amount").isNull() ? null : after.path("amount").asText();
            try (PreparedStatement ps = target.prepareStatement(
                    "UPSERT INTO orders (id, name, amount) VALUES (?, ?, ?)")) {
                ps.setLong(1, id);
                ps.setString(2, name);
                if (amount == null) {
                    ps.setNull(3, Types.NUMERIC);
                }
                else {
                    ps.setBigDecimal(3, new BigDecimal(amount));
                }
                ps.executeUpdate();
            }
            LOGGER.info("apply op={}  id={}  name={}  amount={}", op, id, name, amount);
        }
        catch (Exception e) {
            LOGGER.error("Failed to apply change event (value={}): {}", value, e.getMessage(), e);
        }
    }

    /**
     * Resolves the primary key {@code id} from the record key (preferred, always present), falling
     * back to the {@code after} then {@code before} blocks of the value envelope.
     */
    private static Long resolveId(String key, JsonNode envelope) throws Exception {
        if (key != null && !key.isBlank()) {
            JsonNode idNode = MAPPER.readTree(key).path("id");
            if (!idNode.isMissingNode() && !idNode.isNull()) {
                return idNode.asLong();
            }
        }
        for (String block : new String[]{ "after", "before" }) {
            JsonNode idNode = envelope.path(block).path("id");
            if (!idNode.isMissingNode() && !idNode.isNull()) {
                return idNode.asLong();
            }
        }
        return null;
    }

    private static String env(String key, String defaultValue) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? defaultValue : v;
    }
}
