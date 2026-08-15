package com.example.nav.module.install.service;

import com.example.nav.common.config.WebInstallProperties;
import com.example.nav.common.exception.BusinessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.regex.Pattern;

@Service
public class InstallAccessService {

    private static final Pattern CONFIGURED_TOKEN = Pattern.compile("^[0-9a-f]{64}$");

    private final WebInstallProperties properties;

    public InstallAccessService(WebInstallProperties properties) {
        this.properties = properties;
    }

    public void requireEnabledAndValidToken(String suppliedToken) {
        if (!properties.isEnabled()) {
            throw new BusinessException(HttpStatus.FORBIDDEN, "网页安装功能已关闭");
        }
        if (!isConfiguredTokenValid()) {
            throw new BusinessException(HttpStatus.SERVICE_UNAVAILABLE, "安装口令尚未正确配置");
        }
        if (!matches(suppliedToken)) {
            throw BusinessException.unauthorized("安装口令无效");
        }
    }

    public boolean isConfiguredTokenValid() {
        String configuredToken = properties.getToken();
        return configuredToken != null && CONFIGURED_TOKEN.matcher(configuredToken).matches();
    }

    private boolean matches(String suppliedToken) {
        String expected = properties.getToken();
        if (!isConfiguredTokenValid()) {
            return false;
        }
        byte[] expectedBytes = expected.getBytes(StandardCharsets.UTF_8);
        byte[] suppliedBytes = suppliedToken == null
                ? new byte[0]
                : suppliedToken.getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(expectedBytes, suppliedBytes);
    }
}
