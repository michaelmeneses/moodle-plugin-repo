<?php

$api = "https://download.moodle.org/api/1.3/pluglist.php";
$satisfile = __DIR__ . '/middag.json';

$pluginlistjson = file_get_contents($api);

if (!$pluginlist = json_decode($pluginlistjson)) {
    die("Unable to read plugin list");
}

$satisjson = [];
$satisjson['name'] = "middag/moodle-plugins";
$satisjson['description'] = "Middag - Moodle Plugins";
$satisjson['homepage'] = "http://satis.middag.com.br";
$satisjson['repositories'] = [];
$satisjson['require'] = [];

foreach ($pluginlist->plugins as $key => $plugin) {
    if (empty($plugin->component) || empty($plugin->source)) {
        continue;
    }
    $url = parse_url($plugin->source);
    if (!isset($url['path']) || strpos($plugin->source, 'http:') !== false) {
        continue;
    }
    // Support to Moodle 3.2+
    $suport = false;
    foreach ($plugin->versions as $version) {
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= 2016120500) {
                $suport = true;
            }
        }
    }
    if (!$suport){
        continue;
    }
    $username = trim(str_replace(basename($plugin->source), '', $url['path']), '/');
    $satisjson['repositories'][] = ["type" => "vcs", "url" => $plugin->source];
    $satisjson['require']["$username/$plugin->component"] = "*";
}

file_put_contents($satisfile, json_encode($satisjson));
