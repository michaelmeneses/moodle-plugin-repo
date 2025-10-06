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
 * Get the OpenGraph description from a URL.
 *
 * @param string $url URL to fetch the description from
 * @return string Description found or empty string
 */
function opengraph_get_description(string $url): string
{
    try {
        $graph = opengraph_fetch($url);
        return $graph['description'] ?? '';
    } catch (RuntimeException $e) {
        return '';
    }
}

/**
 * Fetch and extract OpenGraph metadata from a URL.
 *
 * @param string $uri URL to fetch metadata from
 * @return array Extracted OpenGraph metadata
 * @throws RuntimeException If the request fails or no metadata found
 */
function opengraph_fetch(string $uri): array
{
    $html = curl_get_content($uri, [
        CURLOPT_TIMEOUT => 15,
        CURLOPT_USERAGENT => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36',
    ]);

    return opengraph_parse($html);
}

/**
 * Extract OpenGraph metadata from HTML content.
 *
 * @param string $html HTML content to parse
 * @return array Extracted OpenGraph metadata
 * @throws RuntimeException If no valid metadata found
 */
function opengraph_parse(string $html): array
{
    $doc = new DOMDocument();
    @$doc->loadHTML($html);

    $tags = $doc->getElementsByTagName('meta');
    if (!$tags || $tags->length === 0) {
        throw new RuntimeException('No meta tags found in HTML');
    }

    $values = [];
    $nonOgDescription = null;

    foreach ($tags as $tag) {
        // Extract OpenGraph properties
        if ($tag->hasAttribute('property') && str_starts_with($tag->getAttribute('property'), 'og:')) {
            $key = strtr(substr($tag->getAttribute('property'), 3), '-', '_');
            $values[$key] = $tag->getAttribute('content') ?: $tag->getAttribute('value');
            continue;
        }

        // Capture non-OG description as fallback
        if ($tag->hasAttribute('name') && $tag->getAttribute('name') === 'description') {
            $nonOgDescription = $tag->getAttribute('content');
        }
    }

    // Fallback to page title
    if (!isset($values['title'])) {
        $titles = $doc->getElementsByTagName('title');
        if ($titles->length > 0) {
            $values['title'] = $titles->item(0)->textContent;
        }
    }

    // Fallback to non-OG description
    if (!isset($values['description']) && $nonOgDescription !== null) {
        $values['description'] = $nonOgDescription;
    }

    // Fallback to image_src if og:image not present
    if (!isset($values['image'])) {
        $values = extract_image_src_fallback($doc, $values);
    }

    if (empty($values)) {
        throw new RuntimeException('No OpenGraph metadata found');
    }

    return $values;
}

/**
 * Extract image using link rel="image_src" as fallback.
 *
 * @param DOMDocument $doc DOM document
 * @param array $values Current values array
 * @return array Updated values array
 */
function extract_image_src_fallback(DOMDocument $doc, array $values): array
{
    $domxpath = new DOMXPath($doc);
    $elements = $domxpath->query("//link[@rel='image_src']");

    if ($elements->length > 0) {
        $domattr = $elements->item(0)->attributes->getNamedItem('href');
        if ($domattr) {
            $values['image'] = $domattr->value;
            $values['image_src'] = $domattr->value;
        }
    }

    return $values;
}

/**
 * Perform HTTP request using cURL (centralized helper function).
 *
 * @param string $url URL to request
 * @param array $additionalOptions Additional cURL options
 * @return string Response content
 * @throws RuntimeException If the request fails
 */
function curl_get_content(string $url, array $additionalOptions = []): string
{
    $ch = curl_init($url);
    if ($ch === false) {
        throw new RuntimeException('Failed to initialize cURL');
    }

    $defaultOptions = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_FAILONERROR => true,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_USERAGENT => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    ];

    curl_setopt_array($ch, $defaultOptions + $additionalOptions);

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

/**
 * Get content from a URL using cURL with headers for JSON.
 *
 * @param string $url URL to request
 * @return string Response content
 * @throws RuntimeException If the request fails
 */
function get_content_from_url(string $url): string
{
    return curl_get_content($url, [
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Accept-Language: en-US,en;q=0.9',
        ],
    ]);
}
