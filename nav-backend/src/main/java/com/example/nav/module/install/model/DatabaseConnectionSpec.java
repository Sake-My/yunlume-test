package com.example.nav.module.install.model;

import java.util.List;

public record DatabaseConnectionSpec(
        DatabaseConnectionMode mode,
        String host,
        int port,
        String database,
        String username,
        String password,
        DatabaseSslMode sslMode,
        String caCertificatePem,
        List<String> resolvedAddresses
) {
    public DatabaseConnectionSpec {
        resolvedAddresses = resolvedAddresses == null ? List.of() : List.copyOf(resolvedAddresses);
    }

    @Override
    public String toString() {
        return "DatabaseConnectionSpec[mode=" + mode
                + ", host=" + host
                + ", port=" + port
                + ", database=<redacted>, username=<redacted>, password=<redacted>"
                + ", sslMode=" + sslMode
                + ", caCertificatePem=<redacted>, resolvedAddresses=<redacted>]";
    }
}
