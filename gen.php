<?php

use JsonSchema\Validator;

require 'vendor/autoload.php';
require 'util.php';

const MOODLE_LATEST = "4.3";
const MOODLE_LATEST_BEFORE = "4.2";
const MOODLE_35_BUILD = "2018051700";

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
$satisjson['name'] = middag_get_env('SATIS_NAME');
$satisjson['homepage'] = middag_get_env('SATIS_URL');
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
$greatversion = [];
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
    // Support to Moodle 3.2+
    $suport = false;
    $greatversion[$plugin->component] = 0;
    foreach ($plugin->versions as $version) {
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= MOODLE_35_BUILD) {
                $suport = true;
                if ($supportedmoodle->release > $greatversion[$plugin->component]) {
                    $greatversion[$plugin->component] = $supportedmoodle->release;
                }
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
            if ($suport || $supportedmoodle->version >= MOODLE_35_BUILD) {
                $prefix = '';
                $sufix = '.*';
                if ($supportedmoodle->release == MOODLE_LATEST
                    || $supportedmoodle->release == MOODLE_LATEST_BEFORE) {
                    $prefix = ">=";
                    $sufix = '';
                }
                $supportedmoodles[] = $prefix . $supportedmoodle->release . $sufix;
            }
        }

        if ($greatversion[$plugin->component]) {
            $supportedmoodles[] = '>' . $greatversion[$plugin->component];
        }

        $supportedmoodles = implode(' || ', $supportedmoodles);

        $packagename = $vendor . '/moodle-' . $type . '_' . $name;

        $package = [
            'name' => $packagename,
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

        if (isset($description) && $description) {
            $package['description'] = $description;
        }

        $packages[$plugin->component]['package'][$version->version] = $package;
    }

    echo 'Loaded ' . $packagename . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
}

foreach ($packages as $package) {
    $satisjson['repositories'][] = $package;
}

$coremaxversions = [
    '4.4' => 0,
    '4.3' => 4,
    '4.2' => 7,
    '4.1' => 10,
    '4.0' => 12,
    '3.11' => 18,
    '3.10' => 11,
    '3.9' => 25,
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

        echo 'Loaded moodle/moodle - version: ' . $versionno . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
    }
}

$satisjson['repositories'][] = $moodles;

$schemaFile = 'vendor/composer/satis/res/satis-schema.json';
$schemaFileContents = file_get_contents($schemaFile);
$schema = json_decode($schemaFileContents);
$validator = new Validator();
$validator->check((object)$satisjson, $schema);
if (!$validator->isValid()) {
    echo 'Failed validation' . PHP_EOL;
    var_dump($validator->getErrors());
    exit(1);
}

file_put_contents($satisfile, json_encode($satisjson));
