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
    $satisjson['repositories'][] = ["type" => "vcs", "url" => $plugin->source];
    $satisjson['require']["middag/moodle-$plugin->component"] = "*";
}

file_put_contents($satisfile, json_encode($satisjson, JSON_FORCE_OBJECT));
