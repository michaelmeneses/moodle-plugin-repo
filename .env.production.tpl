# Injetar via: op inject -i .env.production.tpl -o .env

# Satis config
SATIS_NAME=middag/satis
SATIS_URL=https://satis.middag.com.br
SATIS_BASEDIR=/opt/moodle-plugin-repo
SATIS_OUTPUTDIR=
REPO_BRANCH=master
PHP_BIN=/usr/bin/php

# Upload files to S3-compatible storage (Cloudflare R2)
AWS_ACCESS_KEY_ID={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/access_key_id }}
AWS_SECRET_ACCESS_KEY={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/secret_access_key }}
AWS_DEFAULT_REGION=auto
AWS_REGION=auto
S3_BUCKET={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/bucket }}
S3_ENDPOINT={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/endpoint }}
S3_USE_PATH_STYLE_ENDPOINT=true

# s3-satis compatible aliases
S3_ACCESS_KEY_ID={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/access_key_id }}
S3_SECRET_ACCESS_KEY={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/secret_access_key }}
S3_REGION=auto
S3_DEFAULT_REGION=auto

# Cloudflare R2 native
R2_BUCKET_NAME={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/bucket }}
R2_ACCOUNT_ID={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/ACCOUNT/account_id }}
R2_ACCESS_KEY_ID={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/access_key_id }}
R2_SECRET_ACCESS_KEY={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/secret_access_key }}
R2_ENDPOINT={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/STORAGE/endpoint }}

# Deploy to Cloudflare Pages
CLOUDFLARE_ACCOUNT_ID={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/ACCOUNT/account_id }}
CLOUDFLARE_API_TOKEN={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/ACCOUNT/api_token }}
CF_PAGES_PROJECT={{ op://CI-SATIS-MOODLE/CLOUDFLARE-satis-moodle/ACCOUNT/pages_project }}
