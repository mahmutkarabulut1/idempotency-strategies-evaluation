package com.idemstudy.config;

import org.apache.curator.framework.CuratorFramework;
import org.apache.curator.framework.CuratorFrameworkFactory;
import org.apache.curator.retry.ExponentialBackoffRetry;
import org.redisson.Redisson;
import org.redisson.api.RedissonClient;
import org.redisson.config.Config;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Client beans for the coordination-dependent strategies. Each is created only
 * when its strategy is selected, so a DB-only run does not open Redis/ZooKeeper
 * connections (and cannot fail on their absence).
 */
@Configuration
public class CoordinationConfig {

    @Bean(destroyMethod = "shutdown")
    @ConditionalOnProperty(name = "idem.strategy", havingValue = "REDIS")
    public RedissonClient redissonClient(@Value("${idem.redis.address}") String address) {
        Config config = new Config();
        config.useSingleServer()
                .setAddress(address)
                .setConnectionPoolSize(64)
                .setConnectionMinimumIdleSize(16)
                .setTimeout(2000)
                .setRetryAttempts(2);
        return Redisson.create(config);
    }

    @Bean(initMethod = "start", destroyMethod = "close")
    @ConditionalOnProperty(name = "idem.strategy", havingValue = "ZK")
    public CuratorFramework curatorFramework(@Value("${idem.zookeeper.connect}") String connect) {
        return CuratorFrameworkFactory.builder()
                .connectString(connect)
                .sessionTimeoutMs(10000)
                .connectionTimeoutMs(3000)
                .retryPolicy(new ExponentialBackoffRetry(200, 3))
                .build();
    }
}
