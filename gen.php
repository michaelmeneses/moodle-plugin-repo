<?php

$satisfile = __DIR__ . '/satis.json';

$folder = '/public_html';
$outputdir = __DIR__ . $folder;

if (!empty($_SERVER['argv'])) {
    $rawoptions = $_SERVER['argv'];
    foreach ($rawoptions as $raw) {
        if (str_starts_with($raw, '--')) {
            $value = substr($raw, 2);
            $parts = explode('=', $value);
            if ($parts[0] == 'satisfile' && isset($parts[1])) {
                $satisfile = $parts[1];
            }
            if ($parts[0] == 'output-dir' && isset($parts[1])) {
                $outputdir = $parts[1];
                if (!str_ends_with($outputdir, $folder)) {
                    $outputdir .= $folder;
                }
            }
        }
    }
}

$api = 'https://download.moodle.org/api/1.3/pluglist.php';
$corebase = 'https://download.moodle.org/download.php/direct';

$satisjson = [];
$satisjson['name'] = 'middag/satis';
$satisjson['homepage'] = 'https://satis.middag.com.br';
$satisjson['repositories'] = [];
$satisjson['require-all'] = true;
$satisjson['require-dependencies'] = false;
$satisjson['require-dev-dependencies'] = false;
$satisjson['output-dir'] = $outputdir;
$satisjson['archive'] = ['directory' => 'dist', 'format' => 'zip'];

$allcomponents = file_get_contents(__DIR__ . '/components.json');
$allcomponents = json_decode($allcomponents, true);

$pluginlistjson = file_get_contents($api);
if (!$pluginlist = json_decode($pluginlistjson)) {
    die("Unable to read plugin list");
}

$packages = [];
foreach ($pluginlist->plugins as $key => $plugin) {
    if (empty($plugin->component) || empty($plugin->source)) {
        continue;
    }
    // Check if source (vcs repository) have a valid URL
    if (filter_var($plugin->source, FILTER_VALIDATE_URL) === false) {
        continue;
    }
    // Check if source (vcs repository) is HTTPS
    $url = parse_url($plugin->source);
    if (!isset($url['path']) || strpos($plugin->source, 'http:') !== false) {
        continue;
    }
    // Support to Moodle 3.2+
    $suport = false;
    foreach ($plugin->versions as $version) {
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= 2015110100) {
                $suport = true;
            }
        }
    }
    if (!$suport) {
        continue;
    }

    // All right
    list($type, $name) = normalize_component($plugin->component, $allcomponents);

    $vendor = 'moodle';
    if (in_array($url['host'], ['github.com', 'gitlab.com', 'bitbucket.org'])) {
        $paths = explode('/', $url['path'], 3);
        if (isset($paths[1]) && !empty($paths[1])) {
            $vendor = mb_strtolower($paths[1], 'UTF-8');
        }
    } else {
        $vendor = 'moodle';
    }

    $packages[$plugin->component] = [
        'type' => 'package',
        'package' => []
    ];

    $timecreated = '';
    if (isset($version->timecreated) && $version->timecreated > 0) {
        $timecreated = date('Y-m-d', $version->timecreated);
    }
    $homepage = 'https://moodle.org/plugins/' . $plugin->component;
    $description = opengraph_get_description($homepage);
    foreach ($plugin->versions as $version) {
        $supportedmoodles = [];
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= 2015110100) {
                $supportedmoodles[] = $supportedmoodle->release . '.*';
            }
        }
        $supportedmoodles = implode(' || ', $supportedmoodles);

        $package = [
            'name' => $vendor . '/moodle-' . $type . '_' . $name,
            'version' => $version->version,
            'type' => 'moodle-' . $type,
            'dist' => [
                'url' => $version->downloadurl,
                'type' => 'zip'
            ],
            'extra' => [
                'installer-name' => $name
            ],
            'require' => [
                'moodle/moodle' => $supportedmoodles,
                'composer/installers' => '~1.0'
            ],
            'homepage' => $homepage,
            'time' => $timecreated,
        ];

        if ($description) {
            $package['description'] = $description;
        }

        $packages[$plugin->component]['package'][] = $package;
    }
}

foreach ($packages as $package) {
    $satisjson['repositories'][] = $package;
}

$coremaxversions = [
    '4.1' => 1,
    '4.0' => 2,
    '3.11' => 8,
    '3.10' => 11,
    '3.9' => 15,
    '3.8' => 9,
    '3.7' => 9,
    '3.6' => 10,
    '3.5' => 18,
    '3.4' => 9,
    '3.3' => 9,
    '3.2' => 9,
];

$moodles = [
    'type' => 'package',
    'package' => []
];
foreach ($coremaxversions as $major => $max) {
    for ($i = $max; $i >= 0; $i--) {
        $versionno = $major . '.' . $i;
        $directory = 'stable' . str_replace('.', '', $major);
        if ($major >= 4) {
            $sub = str_replace('.', '', $major);
            $directory = 'stable' . $sub[0] . '0' . $sub[1];
        }
        $filename = "moodle-$versionno.zip";
        if ($i == '0') {
            $filename = "moodle-$major.zip";
        }
        $url = $corebase . "/$directory/$filename";
        $moodles['package'][] = [
            'name' => 'moodle/moodle',
            'version' => $versionno,
            'dist' => [
                'url' => $url,
                'type' => 'zip'
            ],
            'require' => [
                'composer/installers' => '*'
            ]
        ];
    }
}

$satisjson['repositories'][] = $moodles;

file_put_contents($satisfile, json_encode($satisjson));

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

    curl_setopt($curl, CURLOPT_FAILONERROR, true);
    curl_setopt($curl, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($curl, CURLOPT_TIMEOUT, 15);
    curl_setopt($curl, CURLOPT_SSL_VERIFYHOST, false);
    curl_setopt($curl, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($curl, CURLOPT_USERAGENT, $_SERVER['HTTP_USER_AGENT']);

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
