package com.example.nav.module.health.controller;

import com.example.nav.common.result.Result;
import com.example.nav.module.health.vo.HealthVO;
import com.example.nav.module.install.service.InstallService;
import com.example.nav.module.install.service.DatabaseConfigurationStore;
import com.example.nav.module.install.service.DatabaseIdentityService;
import com.example.nav.module.install.vo.InstallStatusVO;
import io.swagger.v3.oas.annotations.Operation;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;

@RestController
public class HealthController {

    private final JdbcTemplate jdbcTemplate;
    private final ObjectProvider<StringRedisTemplate> redisTemplateProvider;
    private final String cacheType;
    private final InstallService installService;
    private final DatabaseConfigurationStore databaseConfigurationStore;
    private final DatabaseIdentityService databaseIdentityService;

    public HealthController(
            JdbcTemplate jdbcTemplate,
            ObjectProvider<StringRedisTemplate> redisTemplateProvider,
            @Value("${spring.cache.type:simple}") String cacheType,
            InstallService installService,
            DatabaseConfigurationStore databaseConfigurationStore,
            DatabaseIdentityService databaseIdentityService
    ) {
        this.jdbcTemplate = jdbcTemplate;
        this.redisTemplateProvider = redisTemplateProvider;
        this.cacheType = cacheType;
        this.installService = installService;
        this.databaseConfigurationStore = databaseConfigurationStore;
        this.databaseIdentityService = databaseIdentityService;
    }

    @GetMapping("/api/health")
    @Operation(summary = "就绪检查")
    public Result<HealthVO> health() {
        if (databaseConfigurationStore.hasInvalidOrPendingArtifact()) {
            throw new IllegalStateException("Database configuration state is incomplete or invalid");
        }
        if (databaseConfigurationStore.hasPersistedConnection()
                && !databaseIdentityService.isIdentityRequired()) {
            throw new IllegalStateException("Database configuration is waiting for restart");
        }
        if (databaseConfigurationStore.isUnconfiguredSource()) {
            InstallStatusVO installStatus = installService.status();
            if (installStatus.installationRequired() && installStatus.webInstallEnabled()) {
                return Result.success(new HealthVO("INSTALLING", "nav-backend", Instant.now()));
            }
            throw new IllegalStateException("Database is unconfigured while web installation is disabled");
        }
        try {
            jdbcTemplate.queryForObject("SELECT 1", Integer.class);
            if (!databaseIdentityService.ensureVerified()) {
                throw new IllegalStateException(
                        "Database instance identity is unavailable or mismatched");
            }

            if ("redis".equalsIgnoreCase(cacheType)) {
                StringRedisTemplate redisTemplate = redisTemplateProvider.getIfAvailable();
                if (redisTemplate == null) {
                    throw new IllegalStateException("Redis template is unavailable");
                }
                redisTemplate.hasKey("nav:health:probe");
            }
        } catch (RuntimeException exception) {
            InstallStatusVO installStatus = installService.status();
            if (installStatus.installationRequired() && installStatus.webInstallEnabled()) {
                return Result.success(new HealthVO("INSTALLING", "nav-backend", Instant.now()));
            }
            throw exception;
        }

        return Result.success(new HealthVO("UP", "nav-backend", Instant.now()));
    }
}
