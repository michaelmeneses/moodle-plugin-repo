# moodle-plugin-repo

FORK from [https://github.com/micaherne/moodle-plugin-repo](https://github.com/micaherne/moodle-plugin-repo)

This script creates **satis.json** files (format [Composer Satis](https://github.com/composer/satis)) from Moodle
Plugins to run via Satis or s3-satis. Used in **[Middag - Moodle Plugins](https://satis.middag.com.br)**.

## Configuration Modes

This project supports two generation modes:

### 1. **satis** (default)

Generates `satis.json` compatible with the original [Composer Satis](https://github.com/composer/satis).

### 2. **s3-satis**

Generates `satis.json` compatible with [s3-satis](https://github.com/kduma-OSS/CLI-s3-satis) (or
the [modified fork](https://github.com/michaelmeneses/CLI-s3-satis) available soon), a modified version of Satis that
allows publishing repositories directly to S3. Includes specific plugin configurations to optimize the build process.

## How to Generate Files

### Generate satis.json for Original Satis

```bash
php gen.php --mode=satis --satisfile=satis.json
```

### Generate satis.json for s3-satis

```bash
php gen.php --mode=s3-satis --satisfile=s3-satis.json
```

### Additional Options

```bash
# Specify custom output directory
php gen.php --mode=satis --output-dir=/custom/path

# Do not include output-dir in generated JSON
php gen.php --mode=s3-satis --no-output-dir
```

## How to Run the Build

### Using Composer Scripts (Recommended)

```bash
# Build with original Satis
composer build:satis

# Build with s3-satis (requires s3-satis.phar in project root)
composer build:s3-satis
```

### Using Original Satis

**With Satis installed via Composer:**

```bash
./vendor/bin/satis build satis.json public_html --skip-errors
```

**With Satis installed in another directory:**

```bash
php /path/to/satis/bin/satis build satis.json public_html --skip-errors
```

### Using s3-satis

**With s3-satis.phar in the project root:**

```bash
php s3-satis.phar build s3-satis.json --skip-errors
```

**With s3-satis installed globally:**

```bash
s3-satis build s3-satis.json --skip-errors
```

## Complete Workflow

### Using Composer Scripts (Recommended)

**For Original Satis:**

```bash
# One command: generate config + build
composer full:satis
```

**For s3-satis (with S3):**

```bash
# One command: generate config + build + publish to S3
composer full:s3-satis
```

### Manual Workflow

**For Original Satis:**

```bash
# 1. Generate configuration
composer gen:satis
# or: php gen.php --mode=satis --satisfile=satis.json

# 2. Run build
composer build:satis
# or: ./vendor/bin/satis build satis.json public_html --skip-errors
```

**For s3-satis (with S3):**

```bash
# 1. Generate configuration
composer gen:s3-satis
# or: php gen.php --mode=s3-satis --satisfile=s3-satis.json

# 2. Run build and publish to S3
composer build:s3-satis
# or: php s3-satis.phar build s3-satis.json public_html --skip-errors
```

## Available Composer Scripts

```bash
composer gen:satis          # Generate satis.json for original Satis
composer gen:s3-satis       # Generate s3-satis.json for s3-satis
composer build:satis        # Build repository using original Satis
composer build:s3-satis     # Build repository using s3-satis
composer full:satis         # Generate + build with original Satis
composer full:s3-satis      # Generate + build with s3-satis
```

## How to Use

**[Moodle Composer](https://github.com/michaelmeneses/moodle-composer)**   
Manage Moodle LMS and plugins using Composer at a root directory level (example ROOT/moodle).

**[Middag - Moodle Plugins](https://satis.middag.com.br)**   
Add this __Middag - Moodle Plugins__ repository to your composer.json:

```json
{
  "repositories": [
    {
      "type": "composer",
      "url": "https://satis.middag.com.br"
    }
  ]
}
```

**Your Own Repository**   
Add your repository URL to your composer.json:

```json
{
  "repositories": [
    {
      "type": "composer",
      "url": "https://your.satis.domain.com"
    }
  ]
}
```

## Requirements

- PHP 8.2+
- Composer
- [Composer Satis](https://github.com/composer/satis) or [s3-satis](https://github.com/kduma-OSS/CLI-s3-satis)

## Environment Variables

Configure the following variables in the `.env` file:

```env
SATIS_NAME="Your repository name"
SATIS_URL="https://your.satis.domain.com"
```
