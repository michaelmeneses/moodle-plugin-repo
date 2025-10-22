<?php

use JsonSchema\Validator;

require_once __DIR__ . '/vendor/autoload.php';
require_once __DIR__ . '/util.php';
require_once __DIR__ . '/opengraph_cache.php';

const MOODLE_LATEST = "5.1";
const MOODLE_LATEST_BEFORE = "5.0";
const MOODLE_35_BUILD = "2018051700";

$satisfile = __DIR__ . '/satis.json';

$folder = '/public_html';
$outputdir = __DIR__ . $folder;
$no_outputdir = false;
$mode = 'satis'; // 'satis' or 's3-satis'

$cacheFile = __DIR__ . '/opengraph_cache.json';

// Load OpenGraph cache from S3 or local file
$opengraphCache = opengraph_cache_load($cacheFile);

if (!empty($_SERVER['argv'])) {
    $rawoptions = $_SERVER['argv'];
    foreach ($rawoptions as $raw) {
        if (str_starts_with($raw, '--')) {
            $value = substr($raw, 2);
            $parts = explode('=', $value);
            if ($parts[0] === 'satisfile' && isset($parts[1])) {
                $satisfile = $parts[1];
            }
            if ($parts[0] === 'output-dir' && isset($parts[1])) {
                $outputdir = $parts[1];
                if (!str_ends_with($outputdir, $folder)) {
                    $outputdir .= $folder;
                }
            }
            if ($parts[0] === 'no-output-dir') {
                $no_outputdir = true;
            }
            if ($parts[0] === 'mode' && isset($parts[1])) {
                if (in_array($parts[1], ['satis', 's3-satis'])) {
                    $mode = $parts[1];
                } else {
                    die("Invalid mode. Use 'satis' or 's3-satis'");
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
if (!$no_outputdir) {
    $satisjson['output-dir'] = $outputdir;
}
$satisjson['archive'] = (object)['directory' => 'dist', 'format' => 'zip'];

// Add s3-satis configuration only when mode is 's3-satis'
if ($mode === 's3-satis') {
    $satisjson['s3-satis'] = (object)[
        'plugins' => [
            'cache' => [
                'enabled' => true,
                'path' => '/tmp/s3-satis-generator',
                'copy' => true,
            ],
            'skip-step-after-hook' => [
                'enabled' => true,
                'skip' => [
                    'BEFORE_INITIAL_CLEAR_TEMP_DIRECTORY',
                    'BEFORE_REMOVE_MISSING_FILES_FROM_S3'
                ]
            ]
        ]
    ];
}

try {
    $allcomponents = json_decode(file_get_contents(__DIR__ . '/components.json'), true, 512, JSON_THROW_ON_ERROR);
    $pluginlistjson = get_content_from_url($api);
    if (!$pluginlist = json_decode($pluginlistjson, false, 512, JSON_THROW_ON_ERROR)) {
        die("Unable to read plugin list");
    }
} catch (JsonException $e) {
    $allcomponents = [];
    $pluginlist = [];
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
    // Check support for Moodle 3.5+
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

    // Process plugin component and normalize its type and name
    [$type, $name] = normalize_component($plugin->component, $allcomponents);

    $vendor = 'moodle';
    if (in_array($url['host'], ['github.com', 'gitlab.com', 'bitbucket.org'])) {
        $paths = explode('/', $url['path'], 3);
        if (!empty($paths[1])) {
            $vendor = mb_strtolower($paths[1], 'UTF-8');
        }
    }

    $packages[$plugin->component] = [
        'type' => 'package',
        'package' => []
    ];

    $homepage = 'https://moodle.org/plugins/' . $plugin->component;

    $opengraphCache[$homepage] = opengraph_get_cached_info($homepage, $opengraphCache);

    $packagename = $vendor . '/moodle-' . $type . '_' . $name;

    foreach ($plugin->versions as $version) {
        $supportedmoodles = [];
        foreach ($version->supportedmoodles as $supportedmoodle) {
            if ($suport || $supportedmoodle->version >= MOODLE_35_BUILD) {
                $prefix = '';
                $sufix = '.*';
                if ($supportedmoodle->release === MOODLE_LATEST
                    || $supportedmoodle->release === MOODLE_LATEST_BEFORE) {
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

        $timecreated = (isset($version->timecreated) && $version->timecreated > 0) ? date('Y-m-d', $version->timecreated) : '';

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
                'composer/installers' => '~1.0 || ~2.0'
            ],
            'homepage' => $homepage,
            'time' => $timecreated,
        ];

        if (!empty($opengraphCache[$homepage]['description'])) {
            $package['description'] = $opengraphCache[$homepage]['description'];
        }

        $packages[$plugin->component]['package'][$version->version] = $package;
    }

    echo 'Loaded ' . $packagename . ((PHP_SAPI === 'cli') ? PHP_EOL : '<br>');
}

foreach ($packages as $package) {
    $satisjson['repositories'][] = $package;
}

$coremaxversions = [
    '5.1' => 0,
    '5.0' => 3,
    '4.5' => 8,
    '4.4' => 12,
    '4.3' => 12,
    '4.2' => 11,
    '4.1' => 15,
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
        if ($i === 0) {
            $filename = "moodle-$major.zip";
        }
        $url = $corebase . "/$directory/$filename";
        if ($major === '5.0' && $i === 0) {
            // Special case for Moodle 5.0
            $url = 'https://satis.middag.com.br/dist/moodle/moodle/moodle-moodle-5.0.0.zip';
        }
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

try {
    $schemaFile = 'vendor/composer/satis/res/satis-schema.json';
    $schemaFileContents = file_get_contents($schemaFile);
    $schema = json_decode($schemaFileContents, false, 512, JSON_THROW_ON_ERROR);
    $validator = new Validator();
    $satisjson = (object)$satisjson;
    $validator->validate($satisjson, $schema);
    if (!$validator->isValid()) {
        $errors = $validator->getErrors();

        // Remove additional property error for 's3-satis' only when mode is 's3-satis'
        if ($mode === 's3-satis') {
            foreach ($errors as $key => $error) {
                if (isset($error['constraint']['name'], $error['constraint']['params']['property'])) {
                    $constraint = $error['constraint'];
                    if ($constraint['name'] === 'additionalProp' && $constraint['params']['property'] === 's3-satis') {
                        unset($errors[$key]);
                    }
                }
            }
        }

        if (count($errors)) {
            echo 'Failed validation for mode: ' . $mode . PHP_EOL;
            var_dump($errors);
            $errorfile = str_replace('.json', '-error-' . date('Y-m-d-m-Y-H-i-s') . '.json', $satisfile);
            file_put_contents($errorfile, json_encode($satisjson, JSON_THROW_ON_ERROR));
            exit(1);
        }
    }

    // Save OpenGraph cache to local file and S3
    opengraph_cache_save($opengraphCache, $cacheFile);

    // Save satis.json
    file_put_contents($satisfile, json_encode($satisjson, JSON_THROW_ON_ERROR));

} catch (JsonException $e) {
}
