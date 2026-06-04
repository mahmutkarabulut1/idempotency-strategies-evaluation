package com.idemstudy.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

/**
 * The repository interfaces are nested inside {@link com.idemstudy.domain.Repositories}.
 * Spring Data ignores nested repository interfaces by default, so we must enable
 * {@code considerNestedRepositories}.
 */
@Configuration
@EnableJpaRepositories(
        basePackages = "com.idemstudy.domain",
        considerNestedRepositories = true)
public class JpaConfig {
}
