<?php

declare(strict_types=1);

if (file_exists(__DIR__ . '/.env')) {
    $dotenv = Dotenv\Dotenv::createImmutable(__DIR__);
    $dotenv->load();
}

/**
 * Get the value of an environment variable.
 *
 * Searches in $_ENV, getenv() and $_SERVER in this order.
 *
 * @param string $key Environment variable name
 * @param string|null $default Default value if variable doesn't exist
 * @return string|null Variable value or default value
 */
function middag_get_env(string $key, ?string $default = null): ?string
{
    if (isset($_ENV[$key])) {
        return $_ENV[$key];
    }

    $value = getenv($key);
    if ($value !== false) {
        return $value;
    }

    if (isset($_SERVER[$key])) {
        return $_SERVER[$key];
    }

    return $default;
}

/**
 * Normalize the component name using the "frankenstyle" rules.
 *
 * Note: this does not verify the validity of plugin or type names.
 *
 * @param string $component Component name to normalize
 * @param array $allcomponents Array containing all system components
 * @return array Two-items list: [(string)type, (string|null)name]
 */
function normalize_component(string $component, array $allcomponents): array
{
    if ($component === 'moodle' || $component === 'core' || $component === '') {
        return ['core', null];
    }

    if (!str_contains($component, '_')) {
        if (array_key_exists($component, $allcomponents['subsystems'] ?? [])) {
            return ['core', $component];
        }
        // Everything else without underscore is a module.
        return ['mod', $component];
    }

    [$type, $plugin] = explode('_', $component, 2);
    if ($type === 'moodle') {
        $type = 'core';
    }
    // Any unknown type must be a subplugin.

    return [$type, $plugin];
}


/**
 * Get or create S3 client instance (singleton pattern).
 *
 * @return \Aws\S3\S3Client
 * @throws RuntimeException If S3 configuration is missing
 */
function get_s3_client(): \Aws\S3\S3Client
{
    static $client = null;

    if ($client === null) {
        $endpoint = middag_get_env('S3_ENDPOINT');
        $region = middag_get_env('S3_REGION', middag_get_env('AWS_REGION', 'us-east-1'));
        $accessKey = middag_get_env('S3_ACCESS_KEY_ID', middag_get_env('AWS_ACCESS_KEY_ID'));
        $secretKey = middag_get_env('S3_SECRET_ACCESS_KEY', middag_get_env('AWS_SECRET_ACCESS_KEY'));

        if (!$accessKey || !$secretKey) {
            throw new RuntimeException('Missing S3 credentials: ensure S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are set');
        }

        $config = [
            'region' => $region,
            'end' => $region,
            'version' => 'latest',
            'credentials' => new Aws\Credentials\Credentials($accessKey, $secretKey),
        ];

        // Se um endpoint customizado for fornecido (ex: Cloudflare R2), use-o
        if ($endpoint) {
            $config['endpoint'] = $endpoint;
            $config['use_path_style_endpoint'] = true;
        }

        $client = new \Aws\S3\S3Client($config);
    }

    return $client;
}

/**
 * Get an object from S3-compatible storage. Returns null if not found (404).
 *
 * @param string $key Object key
 * @return string|null Body or null if not found
 * @throws RuntimeException If configuration is invalid
 */
function s3_get_object(string $key): ?string
{
    try {
        $client = get_s3_client();
        $bucket = middag_get_env('S3_BUCKET');

        if (!$bucket) {
            throw new RuntimeException('Missing S3_BUCKET configuration');
        }

        $result = $client->getObject([
            'Bucket' => $bucket,
            'Key' => $key,
        ]);

        $body = $result['Body']->getContents();

        // Validar que o conteúdo não está vazio
        if (empty($body)) {
            error_log("S3 GET warning: Object '{$key}' exists but is empty");
            return null;
        }

        return $body;
    } catch (\Aws\S3\Exception\S3Exception $e) {
        $errorCode = $e->getAwsErrorCode();

        // Se o objeto não foi encontrado, retorne null silenciosamente
        if ($errorCode === 'NoSuchKey' || $errorCode === 'NoSuchBucket') {
            return null;
        }

        // Para outros erros S3, fazer log mas não quebrar
        error_log("S3 GET error for '{$key}': [{$errorCode}] " . $e->getMessage());
        return null;
    } catch (Throwable $e) {
        // Erros de configuração ou conectividade
        error_log("S3 GET exception for '{$key}': " . $e->getMessage());
        throw $e;
    }
}

/**
 * Put an object to S3-compatible storage. Returns true on success.
 *
 * @param string $key Object key
 * @param string $content Content to upload
 * @param string $contentType Content-Type header
 * @return bool True on success, false on failure
 * @throws RuntimeException If configuration is invalid
 */
function s3_put_object(string $key, string $content, string $contentType = 'application/octet-stream'): bool
{
    try {
        $client = get_s3_client();
        $bucket = middag_get_env('S3_BUCKET');

        if (!$bucket) {
            throw new RuntimeException('Missing S3_BUCKET configuration');
        }

        // Validar que o conteúdo não está vazio
        if (empty($content)) {
            error_log("S3 PUT warning: Attempting to upload empty content for '{$key}'");
            return false;
        }

        $result = $client->putObject([
            'Bucket' => $bucket,
            'Key' => $key,
            'Body' => $content,
            'ContentType' => $contentType,
            'CacheControl' => 'max-age=3600', // Cache por 1 hora
        ]);

        // Verificar se o upload foi bem-sucedido verificando o ETag
        if (isset($result['ETag'])) {
            return true;
        }

        error_log("S3 PUT warning: Upload completed but no ETag returned for '{$key}'");
        return false;
    } catch (\Aws\S3\Exception\S3Exception $e) {
        $errorCode = $e->getAwsErrorCode();
        error_log("S3 PUT error for '{$key}': [{$errorCode}] " . $e->getMessage());
        return false;
    } catch (Throwable $e) {
        // Erros de configuração ou conectividade
        error_log("S3 PUT exception for '{$key}': " . $e->getMessage());
        throw $e;
    }
}

/**
 * Fetch complete OpenGraph information from a URL using embed/embed library.
 *
 * @param string $url URL to fetch metadata from
 * @param bool $forceRefresh Force refresh even if cached (ignora timestamp)
 * @return array{
 *     title: string,
 *     description: string,
 *     image: string,
 *     url: string,
 *     site_name: string,
 *     author: string,
 *     published_time: string,
 *     keywords: array<string>,
 *     cached_at: int
 * } Structured OpenGraph data with all fields normalized
 */
function opengraph_fetch_info(string $url, bool $forceRefresh = false): array
{
    $currentTimestamp = time();

    $defaultResponse = [
        'title' => '',
        'description' => '',
        'image' => '',
        'url' => $url,
        'site_name' => '',
        'author' => '',
        'published_time' => '',
        'keywords' => [],
        'cached_at' => $currentTimestamp,
    ];

    try {
        $embed = new \Embed\Embed();
        $info = $embed->get($url);

        // Extrair título com fallbacks
        $title = $info->title ?? '';
        if (empty($title)) {
            $metas = $info->getMetas()->all();
            $title = $metas['og:title'] ?? $metas['twitter:title'] ?? '';
        }

        // Extrair descrição com fallbacks
        $description = $info->description ?? '';
        if (empty($description)) {
            $metas = $info->getMetas()->all();
            $description = $metas['og:description']
                ?? $metas['twitter:description']
                ?? $metas['description']
                ?? '';
        }

        // Extrair imagem com fallbacks
        $image = '';
        if ($info->image) {
            $image = (string)$info->image;
        } else {
            $metas = $info->getMetas()->all();
            $image = $metas['og:image'] ?? $metas['twitter:image'] ?? '';
        }

        // Extrair URL canônica
        $canonicalUrl = $info->url ?? $url;

        // Extrair tipo (article, website, etc.)
        $metas = $info->getMetas()->all();

        // Extrair nome do site
        $siteName = $metas['og:site_name'] ?? '';
        if (empty($siteName) && $info->authorName) {
            $siteName = $info->authorName;
        }

        // Extrair autor
        $author = $info->authorName ?? $metas['article:author'] ?? $metas['author'] ?? '';

        // Extrair data de publicação
        $publishedTime = '';
        if ($info->publishedTime) {
            $publishedTime = $info->publishedTime->format('Y-m-d H:i:s');
        } else if (!empty($metas['article:published_time'])) {
            $publishedTime = $metas['article:published_time'];
        }

        // Extrair keywords
        $keywords = [];
        if (!empty($metas['keywords'])) {
            $keywordString = is_array($metas['keywords'])
                ? implode(',', $metas['keywords'])
                : $metas['keywords'];
            $keywords = array_filter(
                array_map('trim', explode(',', $keywordString)),
                fn($k) => !empty($k)
            );
        } else if (!empty($metas['article:tag'])) {
            $tags = is_array($metas['article:tag'])
                ? $metas['article:tag']
                : [$metas['article:tag']];
            $keywords = array_filter($tags, fn($k) => !empty($k));
        }

        return [
            'title' => trim($title),
            'description' => trim($description),
            'image' => trim($image),
            'url' => (string)$canonicalUrl,
            'site_name' => trim($siteName),
            'author' => trim($author),
            'published_time' => trim($publishedTime),
            'keywords' => array_values($keywords),
            'cached_at' => $currentTimestamp,
        ];
    } catch (Throwable $e) {
        // Em caso de erro, retornar estrutura padrão
        return $defaultResponse;
    }
}

/**
 * Get OpenGraph info with cache validation based on expiration days.
 *
 * Uses randomized cache expiration to prevent all entries from expiring simultaneously.
 * Default: 20 days base + random 0-20 days = 20-40 days total per URL.
 *
 * @param string $url URL to fetch metadata from
 * @param array $cache Current cache array (url => data)
 * @param int|null $cacheDays Base number of days before cache expires (null = use env var or default 20)
 * @return array OpenGraph info (will fetch fresh if cache expired or missing)
 */
function opengraph_get_cached_info(string $url, array $cache, ?int $cacheDays = null): array
{
    // Get base cache expiration days (environment variable or default 20)
    if ($cacheDays === null) {
        $cacheDays = (int)middag_get_env('OPENGRAPH_CACHE_DAYS', '20');
    }

    // Add randomization: base days + random variation (0 to 20 days)
    // This prevents all cache entries from expiring at the same time
    $randomVariation = random_int(0, 20);
    $totalCacheDays = $cacheDays + $randomVariation;

    $cacheExpirationSeconds = $totalCacheDays * 86400; // days * seconds per day
    $currentTimestamp = time();

    // Verificar se existe cache para esta URL
    if (isset($cache[$url]) && is_array($cache[$url]) && !empty($cache[$url]['title'])) {
        $cachedData = $cache[$url];

        // Verificar se o cache tem timestamp e se ainda é válido
        if (isset($cachedData['cached_at'])) {
            $cacheAge = $currentTimestamp - $cachedData['cached_at'];

            // Se o cache ainda não expirou, retornar dados em cache
            if ($cacheAge < $cacheExpirationSeconds) {
                return $cachedData;
            }
        }
    }

    // Cache não existe, expirou ou está inválido - buscar novos dados
    return opengraph_fetch_info($url);
}

/**
 * Get content from a URL using cURL with headers for JSON.
 *
 * @param string $url URL to request
 * @return string Response content
 * @throws RuntimeException If the request fails
 */
function get_content_from_url(string $url): string
{
    $ch = curl_init($url);
    if ($ch === false) {
        throw new RuntimeException('Failed to initialize cURL');
    }

    $options = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_FAILONERROR => true,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_USERAGENT => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Accept-Language: en-US,en;q=0.9',
        ],
    ];

    curl_setopt_array($ch, $options);

    $response = curl_exec($ch);
    $error = curl_error($ch);
    $errno = curl_errno($ch);
    curl_close($ch);

    if ($errno !== 0) {
        throw new RuntimeException("cURL error ({$errno}): {$error}");
    }

    if ($response === false || $response === '') {
        throw new RuntimeException('Empty response from cURL request');
    }

    return $response;
}
