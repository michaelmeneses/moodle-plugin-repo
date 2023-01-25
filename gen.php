<?php

$satisfile = __DIR__ . '/satis.json';

if (!empty($_SERVER['argv'])) {
    $rawoptions = $_SERVER['argv'];
    foreach ($rawoptions as $raw) {
        if (substr($raw, 0, 2) === '--') {
            $value = substr($raw, 2);
            $parts = explode('=', $value);
            if (isset($parts[1])) {
                $satisfile = $parts[1];
            }
        }
    }
}

$api = "https://download.moodle.org/api/1.3/pluglist.php";

$pluginlistjson = file_get_contents($api);

if (!$pluginlist = json_decode($pluginlistjson)) {
    die("Unable to read plugin list");
}

$satisjson = [];
$satisjson['name'] = "Middag - Moodle Plugins";
$satisjson['homepage'] = "https://satis.middag.com.br";
$satisjson['repositories'] = [];

$plugins = [];
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
    list($type, $name) = normalize_component($plugin->component);

    $vendor = 'moodle';
    if (in_array($url['host'], ['github.com', 'gitlab.com', 'bitbucket.org'])) {
        $paths = explode('/', $url['path'], 3);
        if (isset($paths[1]) && !empty($paths[1])) {
            $vendor = mb_strtolower($paths[1], 'UTF-8');
        }
    } else {
        $vendor = 'moodle';
    }

    $plugins[$plugin->component] = [
        'type' => 'package',
        'package' => []
    ];

    foreach ($plugin->versions as $version) {
        $supportedmoodles = [];
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= 2015110100) {
                $supportedmoodles[] = $supportedmoodle->release . '.*';
            }
        }
        $supportedmoodles = implode(' || ', $supportedmoodles);
        $plugins[$plugin->component]['package'][] = [
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
            ]
        ];
    }
}

$satisjson['require-all'] = true;
$satisjson['require-dependencies'] = true;
$satisjson['require-dev-dependencies'] = true;
$satisjson['output-dir'] = "public_html";
$satisjson['archive'] = ["directory" => "dist", "format" => "tar"];

foreach ($plugins as $plugin) {
    $satisjson['repositories'][] = $plugin;
}

file_put_contents($satisfile, json_encode($satisjson));

/**
 * Normalize the component name using the "frankenstyle" rules.
 *
 * Note: this does not verify the validity of plugin or type names.
 *
 * @param string $component
 * @return array two-items list of [(string)type, (string|null)name]
 */
function normalize_component($component)
{
    if ($component === 'moodle' or $component === 'core' or $component === '') {
        return array('core', null);
    }

    $components = file_get_contents('components.json');
    $components = json_decode($components, true);
    if (strpos($component, '_') === false) {
        if (array_key_exists($component, $components['subsystems'])) {
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
