طريقة التشغيل (مجانا)
=====================

1) على الكمبيوتر (مرة واحدة) نزّل Flutter من flutter.dev ثم:
     flutter create shareapp
   وبعدها انسخ الملفين دول فوق الموجودين:
     pubspec.yaml       -> shareapp/pubspec.yaml
     lib/main.dart      -> shareapp/lib/main.dart

2) افتح shareapp/android/app/src/main/AndroidManifest.xml
   وحط الأذونات دي جوه <manifest> وقبل <application>:

    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>
    <uses-permission android:name="android.permission.CAMERA"/>

3) افتح shareapp/android/app/build.gradle (أو build.gradle.kts)
   وغيّر minSdk إلى 26.

4) البناء:
     flutter pub get
     flutter build apk --release
   الملف هيطلع في: build/app/outputs/flutter-apk/app-release.apk

لو مفيش كمبيوتر: ارفع المجلد على GitHub وابنيه مجانا من Codemagic.io
(سجّل بحساب GitHub، اختار المشروع، Android، Start build، وتنزّل الـ APK).

ملاحظات:
- التطبيق ده ممنوع على Google Play بسبب QUERY_ALL_PACKAGES و MANAGE_EXTERNAL_STORAGE، بس بيشتغل عادي كـ APK.
- الملفات المستلمة بتتحفظ في: Download/ShareApp
- لو مكتبة device_apps ادّت خطأ مع نسخة Flutter الجديدة، قولي وأبدّلها.
