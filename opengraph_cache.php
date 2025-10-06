<?php

declare(strict_types=1);

/**
 * OpenGraph Cache Manager
 *
 * Gerencia o carregamento e salvamento do cache de informações OpenGraph,
 * com suporte a armazenamento local e S3.
 */

/**
 * Load OpenGraph cache from S3 or local file.
 *
 * @param string $cacheFile Path to local cache file
 * @return array Cache data array
 */
function opengraph_cache_load(string $cacheFile): array
{
    $cache = [];
    $cacheLoadedFromS3 = false;

    echo 'Loading OpenGraph cache...' . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');

    // Try to load from S3 first
    try {
        $s3Cache = s3_get_object('opengraph_cache.json');
        if ($s3Cache !== null) {
            $decoded = json_decode($s3Cache, true);
            if (is_array($decoded)) {
                $cache = $decoded;
                // Save a local copy as backup
                file_put_contents($cacheFile, $s3Cache);
                $cacheLoadedFromS3 = true;
                $cacheSize = count($cache);
                echo "✓ Loaded OpenGraph cache from S3 ({$cacheSize} entries)" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            } else {
                echo "⚠ S3 cache exists but contains invalid JSON, falling back to local file" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            }
        } else {
            echo "ℹ No cache found in S3, will try local file" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
        }
    } catch (Throwable $e) {
        echo "⚠ S3 error: " . $e->getMessage() . ", falling back to local file" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
    }

    // Fallback to local file if S3 failed or returned nothing
    if (!$cache) {
        if (!file_exists($cacheFile)) {
            file_put_contents($cacheFile, json_encode([], JSON_PRETTY_PRINT));
            echo "✓ Created new local cache file" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
        } else {
            $localCache = file_get_contents($cacheFile);
            $decoded = json_decode($localCache, true);
            if (is_array($decoded)) {
                $cache = $decoded;
                $cacheSize = count($cache);
                echo "✓ Loaded OpenGraph cache from local file ({$cacheSize} entries)" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            } else {
                $cache = [];
                echo "⚠ Local cache file contains invalid JSON, starting with empty cache" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            }
        }
    }

    return $cache;
}

/**
 * Save OpenGraph cache to local file and S3.
 *
 * @param array $cache Cache data to save
 * @param string $cacheFile Path to local cache file
 * @return bool True if saved successfully (at least locally)
 */
function opengraph_cache_save(array $cache, string $cacheFile): bool
{
    echo 'Saving OpenGraph cache...' . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');

    // Encode cache to JSON
    $cacheJson = json_encode($cache, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($cacheJson === false) {
        echo "✗ Failed to encode OpenGraph cache to JSON: " . json_last_error_msg() . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
        return false;
    }

    // Save locally
    $localSaved = file_put_contents($cacheFile, $cacheJson);
    if ($localSaved !== false && is_string($cacheJson)) {
        $cacheSize = count($cache);
        $fileSize = round(strlen($cacheJson) / 1024, 2);
        echo "✓ Saved OpenGraph cache locally ({$cacheSize} entries, {$fileSize} KB)" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
    } else {
        echo "✗ Failed to save OpenGraph cache locally" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
        return false;
    }

    // Upload to S3 with retry
    $s3Uploaded = false;
    $maxRetries = 3;
    for ($attempt = 1; $attempt <= $maxRetries; $attempt++) {
        try {
            $result = s3_put_object('opengraph_cache.json', $cacheJson, 'application/json');
            if ($result) {
                $s3Uploaded = true;
                echo "✓ Uploaded OpenGraph cache to S3 (attempt {$attempt})" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
                break;
            } else {
                echo "⚠ S3 upload returned false (attempt {$attempt}/{$maxRetries})" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            }
        } catch (Throwable $e) {
            echo "⚠ S3 upload error (attempt {$attempt}/{$maxRetries}): " . $e->getMessage() . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
            if ($attempt < $maxRetries) {
                sleep(2); // Wait 2 seconds before retry
            }
        }
    }

    if (!$s3Uploaded) {
        echo "✗ Failed to upload OpenGraph cache to S3 after {$maxRetries} attempts (continuing anyway)" . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
    }

    return true;
}
