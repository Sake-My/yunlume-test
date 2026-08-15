package com.example.nav.module.install.controller;

import com.example.nav.common.result.Result;
import com.example.nav.module.install.dto.InstallCompleteDTO;
import com.example.nav.module.install.dto.DatabaseConfigureDTO;
import com.example.nav.module.install.dto.DatabaseConnectionDTO;
import com.example.nav.module.install.service.DatabaseSetupService;
import com.example.nav.module.install.service.InstallService;
import com.example.nav.module.install.vo.DatabaseConfigureVO;
import com.example.nav.module.install.vo.DatabaseTestVO;
import com.example.nav.module.install.vo.InstallCompleteVO;
import com.example.nav.module.install.vo.InstallEnvironmentVO;
import com.example.nav.module.install.vo.InstallStatusVO;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/install")
public class InstallController {

    private final InstallService installService;
    private final DatabaseSetupService databaseSetupService;

    public InstallController(InstallService installService, DatabaseSetupService databaseSetupService) {
        this.installService = installService;
        this.databaseSetupService = databaseSetupService;
    }

    @GetMapping("/status")
    public Result<InstallStatusVO> status(HttpServletResponse response) {
        preventCaching(response);
        return Result.success(installService.status());
    }

    @PostMapping("/complete")
    public Result<InstallCompleteVO> complete(
            @RequestHeader(name = "X-Install-Token", required = false) String installToken,
            @RequestBody InstallCompleteDTO dto,
            HttpServletResponse response
    ) {
        preventCaching(response);
        return Result.success(installService.complete(installToken, dto));
    }

    @PostMapping("/check")
    public Result<InstallEnvironmentVO> check(
            @RequestHeader(name = "X-Install-Token", required = false) String installToken,
            HttpServletResponse response
    ) {
        preventCaching(response);
        return Result.success(installService.check(installToken));
    }

    @PostMapping("/database/test")
    public Result<DatabaseTestVO> testDatabase(
            @RequestHeader(name = "X-Install-Token", required = false) String installToken,
            @Valid @RequestBody DatabaseConnectionDTO dto,
            HttpServletRequest request,
            HttpServletResponse response
    ) {
        preventCaching(response);
        databaseSetupService.requireSecureTransport(request);
        return Result.success(databaseSetupService.test(installToken, dto));
    }

    @PostMapping("/database/configure")
    public Result<DatabaseConfigureVO> configureDatabase(
            @RequestHeader(name = "X-Install-Token", required = false) String installToken,
            @Valid @RequestBody DatabaseConfigureDTO dto,
            HttpServletRequest request,
            HttpServletResponse response
    ) {
        preventCaching(response);
        databaseSetupService.requireSecureTransport(request);
        return Result.success(databaseSetupService.configure(installToken, dto));
    }

    private void preventCaching(HttpServletResponse response) {
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("Pragma", "no-cache");
        response.setHeader("X-Content-Type-Options", "nosniff");
    }
}
