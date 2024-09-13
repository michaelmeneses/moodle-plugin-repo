<?php

$dotenv = Dotenv\Dotenv::createImmutable(__DIR__);
$dotenv->load();

function middag_get_env($key, $default = null)
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
 * @param string $component
 * @return array two-items list of [(string)type, (string|null)name]
 */
function normalize_component($component, $allcomponents)
{
    if ($component === 'moodle' or $component === 'core' or $component === '') {
        return array('core', null);
    }

    if (strpos($component, '_') === false) {
        if (array_key_exists($component, $allcomponents['subsystems'])) {
            $type = 'core';
            $plugin = $component;
        } else {
            // Everything else without underscore is a module.
            $type = 'mod';
            $plugin = $component;
        }

    } else {
        list($type, $plugin) = explode('_', $component, 2);
        if ($type === 'moodle') {
            $type = 'core';
        }
        // Any unknown type must be a subplugin.
    }

    return array($type, $plugin);
}

function opengraph_get_description($url)
{
    if ($graph = opengraph_fetch($url)) {
        if (isset($graph['description'])) {
            return $graph['description'];
        }
    }

    return '';
}

function opengraph_fetch($URI)
{
    $curl = curl_init($URI);

    $user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36';

    curl_setopt($curl, CURLOPT_FAILONERROR, true);
    curl_setopt($curl, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($curl, CURLOPT_TIMEOUT, 15);
    curl_setopt($curl, CURLOPT_SSL_VERIFYHOST, false);
    curl_setopt($curl, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($curl, CURLOPT_USERAGENT, $user_agent);

    $response = curl_exec($curl);

    curl_close($curl);

    if (!empty($response)) {
        return opengraph_parse($response);
    } else {
        return false;
    }
}

function opengraph_parse($HTML)
{
    $old_libxml_error = libxml_use_internal_errors(true);

    $doc = new DOMDocument();
    $doc->loadHTML($HTML);

    libxml_use_internal_errors($old_libxml_error);

    $tags = $doc->getElementsByTagName('meta');
    if (!$tags || $tags->length === 0) {
        return false;
    }

    $values = [];

    $nonOgDescription = null;

    foreach ($tags as $tag) {
        if ($tag->hasAttribute('property') &&
            strpos($tag->getAttribute('property'), 'og:') === 0) {
            $key = strtr(substr($tag->getAttribute('property'), 3), '-', '_');
            $values[$key] = $tag->getAttribute('content');
        }

        //Added this if loop to retrieve description values from sites like the New York Times who have malformed it.
        if ($tag->hasAttribute('value') && $tag->hasAttribute('property') &&
            strpos($tag->getAttribute('property'), 'og:') === 0) {
            $key = strtr(substr($tag->getAttribute('property'), 3), '-', '_');
            $values[$key] = $tag->getAttribute('value');
        }
        //Based on modifications at https://github.com/bashofmann/opengraph/blob/master/src/OpenGraph/OpenGraph.php
        if ($tag->hasAttribute('name') && $tag->getAttribute('name') === 'description') {
            $nonOgDescription = $tag->getAttribute('content');
        }

    }
    //Based on modifications at https://github.com/bashofmann/opengraph/blob/master/src/OpenGraph/OpenGraph.php
    if (!isset($values['title'])) {
        $titles = $doc->getElementsByTagName('title');
        if ($titles->length > 0) {
            $values['title'] = $titles->item(0)->textContent;
        }
    }
    if (!isset($values['description']) && $nonOgDescription) {
        $values['description'] = $nonOgDescription;
    }

    //Fallback to use image_src if ogp::image isn't set.
    if (!isset($values['image'])) {
        $domxpath = new DOMXPath($doc);
        $elements = $domxpath->query("//link[@rel='image_src']");

        if ($elements->length > 0) {
            $domattr = $elements->item(0)->attributes->getNamedItem('href');
            if ($domattr) {
                $values['image'] = $domattr->value;
                $values['image_src'] = $domattr->value;
            }
        }
    }

    if (empty($values)) {
        return false;
    }

    return $values;
}
