package com.example.nav.module.install.service;

import com.example.nav.common.config.WebInstallProperties;
import com.example.nav.module.install.vo.InstallStatusVO;
import com.example.nav.module.upload.config.UploadStorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.sql.ResultSet;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class InstallServiceTest {

    private static final String INSTALL_TOKEN =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    @Mock
    private JdbcTemplate jdbcTemplate;
    @Mock
    private ObjectProvider<StringRedisTemplate> redisTemplateProvider;
    @Mock
    private PasswordEncoder passwordEncoder;
    @Mock
    private InstallTransactionService transactionService;
    @Mock
    private InstallAccessService accessService;
    @Mock
    private DatabaseConfigurationStore configurationStore;
    @Mock
    private DatabaseIdentityService databaseIdentityService;
    @Mock
    private ResultSet resultSet;

    @Test
    @SuppressWarnings("rawtypes")
    void unavailableDatabaseProducesUnknownInsteadOfClaimingInstallationIsRequired() {
        when(jdbcTemplate.queryForObject(anyString(), any(RowMapper.class)))
                .thenThrow(new IllegalStateException("database unavailable"));

        InstallStatusVO status = service("", "redis").status();

        assertEquals("UNKNOWN", status.state());
        assertFalse(status.installationRequired());
        assertFalse(status.ready());
        verifyNoInteractions(redisTemplateProvider, passwordEncoder, transactionService);
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void anonymousFreshStatusDoesNotProbeUploadOrRedis() throws Exception {
        when(accessService.isConfiguredTokenValid()).thenReturn(true);
        when(resultSet.getLong("user_count")).thenReturn(0L);
        when(resultSet.getLong("site_config_count")).thenReturn(1L);
        when(resultSet.getLong("completed_count")).thenReturn(0L);
        when(jdbcTemplate.queryForObject(anyString(), any(RowMapper.class)))
                .thenAnswer(invocation -> ((RowMapper) invocation.getArgument(1)).mapRow(resultSet, 0));

        InstallStatusVO status = service("", "redis").status();

        assertEquals("REQUIRED", status.state());
        assertTrue(status.installationRequired());
        assertTrue(status.ready());
        verifyNoInteractions(redisTemplateProvider, passwordEncoder, transactionService);
    }

    private InstallService service(String uploadDirectory, String cacheType) {
        WebInstallProperties properties = new WebInstallProperties();
        properties.setEnabled(true);
        properties.setToken(INSTALL_TOKEN);
        UploadStorageProperties upload = new UploadStorageProperties();
        upload.setDirectory(uploadDirectory);
        return new InstallService(
                properties,
                upload,
                jdbcTemplate,
                redisTemplateProvider,
                cacheType,
                passwordEncoder,
                transactionService,
                accessService,
                configurationStore,
                databaseIdentityService
        );
    }
}
