import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class SqliteService {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'movie_app.db');
    return await openDatabase(
      path,
      version: 18,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE users ADD COLUMN username TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE categories(
          id TEXT PRIMARY KEY,
          name TEXT UNIQUE
        )
      ''');
      await db.execute('ALTER TABLE movies ADD COLUMN categoryId TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE movies ADD COLUMN description TEXT');
      await db.execute('ALTER TABLE movies ADD COLUMN views INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE movies ADD COLUMN rating REAL DEFAULT 0.0');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE movies ADD COLUMN year TEXT');
      await db.execute('ALTER TABLE movies ADD COLUMN duration TEXT');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE movies ADD COLUMN detailsUrl TEXT');
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE movies ADD COLUMN backdrop TEXT');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE movies ADD COLUMN backdropUrl TEXT');
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE movies ADD COLUMN subtitleRss TEXT');
    }
    if (oldVersion < 10) {
      await db.execute('ALTER TABLE movies RENAME COLUMN subtitleRss TO subtitleUrl');
    }
    if (oldVersion < 11) {
      await db.execute('ALTER TABLE movies ADD COLUMN isPopular INTEGER DEFAULT 0');
    }
    if (oldVersion < 12) {
      await db.execute('ALTER TABLE video_options ADD COLUMN language TEXT');
    }
    if (oldVersion < 13) {
      await db.execute('''
        CREATE TABLE downloads(
          id TEXT PRIMARY KEY,
          movieId TEXT,
          movieName TEXT,
          imagePath TEXT,
          videoUrl TEXT,
          resolution TEXT,
          savePath TEXT,
          progress REAL DEFAULT 0.0,
          status TEXT,
          createdAt TEXT
        )
      ''');
    }
    if (oldVersion < 14) {
      await db.execute('ALTER TABLE downloads ADD COLUMN headers TEXT');
    }
    if (oldVersion < 15) {
      await db.execute('''
        CREATE TABLE series_categories(
          id TEXT PRIMARY KEY,
          name TEXT UNIQUE
        )
      ''');
      await db.execute('''
        CREATE TABLE series(
          id TEXT PRIMARY KEY,
          name TEXT,
          imagePath TEXT,
          categoryId TEXT,
          description TEXT,
          detailsUrl TEXT,
          backdrop TEXT,
          backdropUrl TEXT,
          views INTEGER DEFAULT 0,
          rating REAL DEFAULT 0.0,
          year TEXT,
          isPopular INTEGER DEFAULT 0,
          createdAt TEXT,
          FOREIGN KEY (categoryId) REFERENCES series_categories (id) ON DELETE SET NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE seasons(
          id TEXT PRIMARY KEY,
          seriesId TEXT,
          seasonNumber INTEGER,
          name TEXT,
          FOREIGN KEY (seriesId) REFERENCES series (id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE episodes(
          id TEXT PRIMARY KEY,
          seasonId TEXT,
          episodeNumber INTEGER,
          name TEXT,
          url TEXT,
          urls TEXT, -- Store JSON list of {url, optionId, quality}
          FOREIGN KEY (seasonId) REFERENCES seasons (id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE series_options(
          id TEXT PRIMARY KEY,
          seriesId TEXT,
          serverImagePath TEXT,
          resolution TEXT,
          videoUrl TEXT,
          language TEXT,
          FOREIGN KEY (seriesId) REFERENCES series (id) ON DELETE CASCADE
        )
      ''');
    }
    if (oldVersion < 16) {
      await db.execute('ALTER TABLE downloads ADD COLUMN isSeries INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE downloads ADD COLUMN seasonNumber INTEGER');
      await db.execute('ALTER TABLE downloads ADD COLUMN episodeNumber INTEGER');
    }
    if (oldVersion < 17) {
       // Add urls column to episodes for multiple servers support
       try { await db.execute('ALTER TABLE episodes ADD COLUMN urls TEXT'); } catch (_) {}
    }
    if (oldVersion < 18) {
      await db.execute('''
        CREATE TABLE watch_history(
          id TEXT PRIMARY KEY,
          mediaId TEXT NOT NULL,
          episodeId TEXT,
          mediaType TEXT NOT NULL,
          lastPosition INTEGER NOT NULL,
          totalDuration INTEGER NOT NULL,
          lastWatchedAt TEXT NOT NULL,
          title TEXT,
          subtitle TEXT,
          imagePath TEXT
        )
      ''');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users(
        id TEXT PRIMARY KEY,
        firstName TEXT,
        lastName TEXT,
        email TEXT UNIQUE,
        username TEXT UNIQUE,
        password TEXT,
        role TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY,
        name TEXT UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE movies(
        id TEXT PRIMARY KEY,
        name TEXT,
        imagePath TEXT,
        categoryId TEXT,
        description TEXT,
        detailsUrl TEXT,
        backdrop TEXT,
        backdropUrl TEXT,
        views INTEGER DEFAULT 0,
        rating REAL DEFAULT 0.0,
        year TEXT,
        duration TEXT,
        subtitleUrl TEXT,
        isPopular INTEGER DEFAULT 0,
        createdAt TEXT,
        FOREIGN KEY (categoryId) REFERENCES categories (id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE video_options(
        id TEXT PRIMARY KEY,
        movieId TEXT,
        serverImagePath TEXT,
        resolution TEXT,
        videoUrl TEXT,
        language TEXT,
        FOREIGN KEY (movieId) REFERENCES movies (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE downloads(
        id TEXT PRIMARY KEY,
        movieId TEXT,
        movieName TEXT,
        imagePath TEXT,
        videoUrl TEXT,
        resolution TEXT,
        savePath TEXT,
        progress REAL DEFAULT 0.0,
        status TEXT,
        createdAt TEXT,
        headers TEXT,
        isSeries INTEGER DEFAULT 0,
        seasonNumber INTEGER,
        episodeNumber INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE series_categories(
        id TEXT PRIMARY KEY,
        name TEXT UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE series(
        id TEXT PRIMARY KEY,
        name TEXT,
        imagePath TEXT,
        categoryId TEXT,
        description TEXT,
        detailsUrl TEXT,
        backdrop TEXT,
        backdropUrl TEXT,
        views INTEGER DEFAULT 0,
        rating REAL DEFAULT 0.0,
        year TEXT,
        isPopular INTEGER DEFAULT 0,
        createdAt TEXT,
        FOREIGN KEY (categoryId) REFERENCES series_categories (id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE seasons(
        id TEXT PRIMARY KEY,
        seriesId TEXT,
        seasonNumber INTEGER,
        name TEXT,
        FOREIGN KEY (seriesId) REFERENCES series (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE episodes(
        id TEXT PRIMARY KEY,
        seasonId TEXT,
        episodeNumber INTEGER,
        name TEXT,
        url TEXT,
        urls TEXT,
        FOREIGN KEY (seasonId) REFERENCES seasons (id) ON DELETE CASCADE
      )
    ''');

     await db.execute('''
      CREATE TABLE series_options(
        id TEXT PRIMARY KEY,
        seriesId TEXT,
        serverImagePath TEXT,
        resolution TEXT,
        videoUrl TEXT,
        language TEXT,
        FOREIGN KEY (seriesId) REFERENCES series (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE watch_history(
        id TEXT PRIMARY KEY,
        mediaId TEXT NOT NULL,
        episodeId TEXT,
        mediaType TEXT NOT NULL,
        lastPosition INTEGER NOT NULL,
        totalDuration INTEGER NOT NULL,
        lastWatchedAt TEXT NOT NULL,
        title TEXT,
        subtitle TEXT,
        imagePath TEXT
      )
    ''');
  }
}
