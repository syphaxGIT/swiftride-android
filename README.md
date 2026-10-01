# SwiftRide Android

Application Flutter Android de gestion de location de voitures, avec les écrans Accueil, Clients, Véhicules et Contrats. Au premier démarrage, une base SQLite vide est créée dans le stockage privé de l’application. Les fiches, contrats et photos sont ensuite conservés localement sur le téléphone.

## Lancer sur Android

Le téléphone doit avoir le débogage USB activé, être connecté en USB et avoir autorisé cet ordinateur. Avec Flutter et le SDK Android installés, depuis ce dossier :

```powershell
flutter run
```

Pour réinstaller la version compilée, le fichier APK de débogage est produit dans `build/app/outputs/flutter-apk/app-debug.apk`.

## Vérification

`flutter analyze` et `flutter test` passent. L’application a été installée et lancée sur le téléphone RMX3710 (Android 15).

## Contrats, photos et données

L’onglet Contrats permet d’enregistrer une période datée, générer un numéro et conserver l’heure exacte de création, filtrer les contrats actifs/expirés/annulés, annuler une location, créer un PDF, le partager via les applications compatibles (courriel, messagerie et réseaux sociaux) et ouvrir la boîte d’impression Android. Le PDF est un modèle/récapitulatif : il ne remplace pas un contrat juridiquement vérifié.

Les photos de véhicules et du permis sont stockées dans les fichiers privés de l’application ; les nouveaux chemins sont enregistrés dans SQLite. La disponibilité du parc est calculée à partir des périodes non annulées qui couvrent la date actuelle. Les locations qui se chevauchent pour le même véhicule sont refusées.

Les données personnelles ne sont pas incluses dans le dépôt ou l’APK. Toutes les données et photos restent locales à l’appareil : il n’y a pas de synchronisation avec le PC ou d’autres téléphones. Sauvegardez séparément les données de l’application si nécessaire.
