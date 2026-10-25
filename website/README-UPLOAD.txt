JH Mirror website: upload to Hostinger
=======================================

1. Hostinger hPanel -> Websites -> your site -> File Manager -> open public_html.
2. Upload jh-mirror-website.zip into public_html and choose "Extract".
   index.html must end up directly inside public_html (not in a sub-folder).
3. Set your download link: open js/config.js and change

       DOWNLOAD_URL: '',

   to your .dmg link, for example

       DOWNLOAD_URL: 'https://yourdomain.com/downloads/JH-Mirror.dmg',

   Every "Download" button on the page uses this one setting.
   (You can upload JH-Mirror.dmg to public_html/downloads/ and use that address.)
4. Set your source code link: in js/config.js change SOURCE_URL: '' to the
   public repository, for example 'https://github.com/yourname/jh-mirror'.
   The "View the source code" buttons stay hidden until this is set.
5. For search engines, once you know the site address, open index.html and
   add these lines inside <head> (replace yourdomain.com):

       <link rel="canonical" href="https://yourdomain.com/">
       <meta property="og:url" content="https://yourdomain.com/">

   and change the og:image line to the full address:

       <meta property="og:image" content="https://yourdomain.com/assets/img/og-image.jpg">

   Then add the site in Google Search Console and request indexing.

Files
- index.html             the page
- css/style.css          all styles
- js/config.js           download link + version number (edit this)
- js/main.js             menu, video player, animations
- assets/video/          the promo film (1080p and 720p for phones)
- assets/img/            real app screenshots, logo, icons, share image
- .htaccess              caching and file types for Hostinger
