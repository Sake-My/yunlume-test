package com.example.nav.common.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

/** Rejects incomplete external Redis settings before a production instance is ready. */
@Component
@Profile("prod")
@Order(Ordered.HIGHEST_PRECEDENCE)
public class ProductionRedisConfigurationValidator implements ApplicationRunner {

    private final ExternalRedisProperties properties;
    private final String cacheType;

    public ProductionRedisConfigurationValidator(
            ExternalRedisProperties properties,
            @Value("${spring.cache.type:simple}") String cacheType
    ) {
        this.properties = properties;
        this.cacheType = cacheType;
    }

    @Override
    public void run(ApplicationArguments args) {
        properties.validateForProduction(cacheType);
    }
}
