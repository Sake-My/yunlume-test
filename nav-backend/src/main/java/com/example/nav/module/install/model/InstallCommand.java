package com.example.nav.module.install.model;

public record InstallCommand(
        String siteName,
        String siteDescription,
        String username,
        String nickname,
        String encodedPassword
) {
}
