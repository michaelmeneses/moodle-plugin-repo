# moodle-plugin-repo   
FORK from [https://github.com/micaherne/moodle-plugin-repo](https://github.com/micaherne/moodle-plugin-repo)   

This script create the file **satis.json** (format [Composer Satis](https://github.com/composer/satis)) from the Moodle Plugins to run via Satis. Used to **[Middag - Moodle Plugins](https://satis.middag.com.br)**.  

### How run   
```
php /path/to/satis/bin/satis build --skip-errors
```

### How use   

**[Moodle Composer](https://github.com/michaelmeneses/moodle-composer)**   
Manage Moodle LMS and plugins using Composer at a root directory level (example ROOT/moodle).   
   
**[Middag - Moodle Plugins](https://satis.middag.com.br)**   
Add this __Middag - Moodle Plugins__ repository to your composer.json   
```
{
  "repositories": [{
    "type": "composer",
    "url": "https://satis.middag.com.br"
  }]
}
```

**Your new repository**   
Add your URL repository to your composer.json   
```
{
  "repositories": [{
    "type": "composer",
    "url": "https://your.satis.domain.com"
  }]
}
```
