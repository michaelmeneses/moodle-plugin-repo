<?php

$api = "https://download.moodle.org/api/1.3/pluglist.php";
$satisfile = __DIR__ . '/satis.json';

$pluginlistjson = file_get_contents($api);

if (!$pluginlist = json_decode($pluginlistjson)) {
    die("Unable to read plugin list");
}

$satisjson = [];
$satisjson['name'] = "Middag - Moodle Plugins";
$satisjson['homepage'] = "https://satis.middag.com.br";
$satisjson['repositories'] = [];

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
    $satisjson['repositories'][] = ["type" => "vcs", "url" => $plugin->source];
}

$satisjson['require-all'] = true;
$satisjson['require-dependencies'] = true;
$satisjson['require-dev-dependencies'] = true;
$satisjson['output-dir'] = "public_html";
$satisjson['archive'] = ["directory" => "dist", "format" => "tar"];

file_put_contents($satisfile, json_encode($satisjson));
