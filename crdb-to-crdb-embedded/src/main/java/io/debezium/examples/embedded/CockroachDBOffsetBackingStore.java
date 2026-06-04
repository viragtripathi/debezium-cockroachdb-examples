/*
 * Copyright Debezium Authors.
 *
 * Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
 */
package io.debezium.examples.embedded;

import java.nio.ByteBuffer;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Collections;
import java.util.Map;
import java.util.Set;

import org.apache.kafka.connect.runtime.WorkerConfig;
import org.apache.kafka.connect.storage.MemoryOffsetBackingStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * A tiny offset store that persists the Debezium connector cursor <b>in CockroachDB itself</b>,
 * so the embedded pipeline needs no Kafka and no local state file.
 *
 * <p>It extends {@link MemoryOffsetBackingStore} (the in-memory store the embedded engine uses) and
 * only adds persistence: load the saved offsets on {@code start()} and write them back on each
 * {@code save()} -- the same pattern Kafka's {@code FileOffsetBackingStore} uses for a file, but
 * pointed at a CockroachDB table. Self-contained on purpose: no extra Debezium storage artifact is
 * required.</p>
 *
 * <p>Configured via plain engine properties:
 * {@code offset.storage.crdb.url|user|password|table}.</p>
 */
public class CockroachDBOffsetBackingStore extends MemoryOffsetBackingStore {

    private static final Logger LOGGER = LoggerFactory.getLogger(CockroachDBOffsetBackingStore.class);

    private String url;
    private String user;
    private String password;
    private String table;

    @Override
    public void configure(WorkerConfig config) {
        super.configure(config);
        Map<String, String> props = config.originalsStrings();
        url = props.get("offset.storage.crdb.url");
        user = props.getOrDefault("offset.storage.crdb.user", "root");
        password = props.getOrDefault("offset.storage.crdb.password", "");
        table = props.getOrDefault("offset.storage.crdb.table", "debezium_offsets");
        if (url == null || url.isBlank()) {
            throw new IllegalArgumentException("offset.storage.crdb.url is required for CockroachDBOffsetBackingStore");
        }
    }

    @Override
    public synchronized void start() {
        super.start();
        try (Connection conn = connect()) {
            try (Statement stmt = conn.createStatement()) {
                stmt.execute("CREATE TABLE IF NOT EXISTS " + table + " (k BYTES PRIMARY KEY, v BYTES)");
            }
            try (Statement stmt = conn.createStatement();
                    ResultSet rs = stmt.executeQuery("SELECT k, v FROM " + table)) {
                while (rs.next()) {
                    byte[] k = rs.getBytes(1);
                    byte[] v = rs.getBytes(2);
                    data.put(ByteBuffer.wrap(k), v == null ? null : ByteBuffer.wrap(v));
                }
            }
            LOGGER.info("Loaded {} offset entries from CockroachDB table {}", data.size(), table);
        }
        catch (SQLException e) {
            throw new RuntimeException("Failed to load offsets from CockroachDB: " + e.getMessage(), e);
        }
    }

    @Override
    protected void save() {
        try (Connection conn = connect()) {
            for (Map.Entry<ByteBuffer, ByteBuffer> entry : data.entrySet()) {
                try (PreparedStatement ps = conn.prepareStatement(
                        "UPSERT INTO " + table + " (k, v) VALUES (?, ?)")) {
                    ps.setBytes(1, toBytes(entry.getKey()));
                    if (entry.getValue() == null) {
                        ps.setNull(2, java.sql.Types.BINARY);
                    }
                    else {
                        ps.setBytes(2, toBytes(entry.getValue()));
                    }
                    ps.executeUpdate();
                }
            }
        }
        catch (SQLException e) {
            throw new RuntimeException("Failed to save offsets to CockroachDB: " + e.getMessage(), e);
        }
    }

    /**
     * Source-partition enumeration is only used for partition listing / exactly-once coordination,
     * which this single-connector at-least-once demo does not rely on (offset resume goes through
     * {@code get()} against the persisted {@code data} map). An empty set is correct here.
     */
    @Override
    public Set<Map<String, Object>> connectorPartitions(String connectorName) {
        return Collections.emptySet();
    }

    private Connection connect() throws SQLException {
        return DriverManager.getConnection(url, user, password);
    }

    private static byte[] toBytes(ByteBuffer buffer) {
        byte[] bytes = new byte[buffer.remaining()];
        buffer.duplicate().get(bytes);
        return bytes;
    }
}
