package com.example.nav.module.install.service;

import com.example.nav.common.config.WebInstallProperties;
import com.example.nav.common.exception.BusinessException;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class InstallAccessServiceTest {

    private static final String TOKEN =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    @Test
    void onlyExactCanonicalTokenIsAccepted() {
        WebInstallProperties properties = new WebInstallProperties();
        properties.setEnabled(true);
        properties.setToken(TOKEN);
        InstallAccessService service = new InstallAccessService(properties);

        assertDoesNotThrow(() -> service.requireEnabledAndValidToken(TOKEN));
        BusinessException wrong = assertThrows(
                BusinessException.class,
                () -> service.requireEnabledAndValidToken("wrong"));
        assertEquals(401, wrong.getStatus().value());
    }

    @Test
    void disabledInstallerWinsBeforeTokenComparison() {
        WebInstallProperties properties = new WebInstallProperties();
        properties.setEnabled(false);
        properties.setToken(TOKEN);

        BusinessException exception = assertThrows(
                BusinessException.class,
                () -> new InstallAccessService(properties).requireEnabledAndValidToken(TOKEN));
        assertEquals(403, exception.getStatus().value());
    }
}
