package com.example.nav.module.install.dto;

import com.example.nav.module.install.model.DatabaseConnectionMode;
import com.example.nav.module.install.model.DatabaseSslMode;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record DatabaseConnectionDTO(
        @NotNull(message = "数据库模式不能为空")
        DatabaseConnectionMode mode,

        @Size(max = 253, message = "数据库主机名过长")
        String host,

        Integer port,

        @Size(max = 63, message = "数据库名称过长")
        String database,

        @Size(max = 128, message = "数据库用户名过长")
        String username,

        @Size(max = 1024, message = "数据库密码过长")
        String password,

        DatabaseSslMode sslMode,

        @Size(max = 65536, message = "CA 证书不能超过 64KiB")
        String caCertificatePem,

        Boolean acknowledgeUnverifiedTls
) {
    @Override
    public String toString() {
        return "DatabaseConnectionDTO[mode=" + mode
                + ", host=<redacted>, port=" + port
                + ", database=<redacted>, username=<redacted>, password=<redacted>"
                + ", sslMode=" + sslMode
                + ", caCertificatePem=<redacted>, acknowledgeUnverifiedTls="
                + acknowledgeUnverifiedTls + "]";
    }
}
