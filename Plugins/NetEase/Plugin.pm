package Plugins::NetEase::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catfile);
use POSIX qw(strftime);
use Slim::Utils::Misc;
use Slim::Utils::Unicode;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Cache;
use Slim::Control::Request;

my $prefs = preferences('plugin.netease');
my $log   = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.netease',
	'defaultLevel' => 'INFO',
	'description'  => 'NetEase Cloud Music',
});

my $cache = Slim::Utils::Cache->new;

# 一次性检查歌曲可播放性的上限。超过这个数量时跳过预检查，
# 播放时再由 ProtocolHandler 解析真实 URL，避免拖慢菜单加载。
use constant MAX_PRECHECK_TRACKS => 300;

# 红心歌单分页大小：超过这个数量时拆成多个可整页播放的入口，
# 避免一次性加载上千首导致菜单打开过慢。
use constant LIKED_PAGE_SIZE => 300;

# 普通歌单分页大小。/playlist/track/all 单次最多返回 1000 首，
# 超过这个数量时同样拆成多个可整页播放的入口。
use constant PLAYLIST_PAGE_SIZE => 1000;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		backend         => 'api',
		apiBase         => 'http://127.0.0.1:3000',
		realIP          => '',
		cookie          => '',
		uid             => '',
		nickname        => '',
		verified        => 0,
		quality         => 'exhigh',
		downloadDir     => '',
		downloadQuality => 'standard',
		likedPageSize   => 300,
		precheckLimit   => 300,
	});

	require Plugins::NetEase::API;
	require Plugins::NetEase::Downloader;
	require Plugins::NetEase::ProtocolHandler;

	Plugins::NetEase::ProtocolHandler->init;

	# 注册设置页；不调用 Settings->new() 时该 URL 不会被 LMS 路由，访问会 404。
	# WEBUI 由 slimserver.pl 中的 use constant 定义，用函数调用形式以便静态检查。
	if ( eval { main::WEBUI() } ) {
		require Plugins::NetEase::Settings;
		Plugins::NetEase::Settings->new();

		require Plugins::NetEase::Downloads;
		Plugins::NetEase::Downloads->new();
	}

	Slim::Control::Request::addDispatch(
		['netease', 'download', '_what', '_id'],
		[0, 0, 1, \&cliDownload],
	);

	Slim::Control::Request::addDispatch(
		['netease', 'savetolocal', '_what', '_id'],
		[0, 0, 1, \&cliSaveToLocal],
	);

	Slim::Control::Request::addDispatch(
		['netease', 'lyrics', '_id'],
		[0, 0, 1, \&cliLyrics],
	);

	# === Override MAI lyrics CLI for NetEase tracks ===
	# LMS addDispatch 文档明确说：后注册的会替换已存在的，并返回被替换的原函数 ref。
	# 但前提是我们的 initPlugin 必须在 MAI TrackInfo->init() 之后执行。
	# 如果 addDispatch 返回 undef 说明之前没人注册过——那 MAI 可能还没加载，
	# 我们就用延迟 timer 等到 MAI 加载完再覆盖。

	my $netease_lyrics_wrapper = sub {
		my $request = shift;

		# 从 request 里拿 url / track_id 参数
		my $url     = $request->getParam('url')     || '';
		my $trackId = $request->getParam('track_id') || '';

		# 网易云 song id 提取（多种格式都能抓到）
		my $sid;
		if ( $url =~ m{netease://track/(\d+)} ) {
			# 原始 URL: netease://track/1396343703
			$sid = $1;
		}
		elsif ( $trackId =~ m{^(\d{7,})$} ) {
			# 纯数字 track_id（LMS DB 对象）
			$sid = $1;
		}
		elsif ( $url =~ m{(\d{7,})} ) {
			# 代理流 URL 里藏着的网易云 song id（任何 7+ 位数字串）
			# 代理流如 http://host:port/stream.mp3?...netease_track_id=1396343703...
			$sid = $1;
		}

		# 不是网易云 → 动态转给 MAI 原始 handler（如果存在）
		if ( !$sid ) {
			if ( Plugins::MusicArtistInfo::TrackInfo->can('getSongLyricsCLI') ) {
				return Plugins::MusicArtistInfo::TrackInfo::getSongLyricsCLI($request);
			}
			# MAI 没加载
			$request->setStatusBadDispatch();
			return;
		}

		# === 网易云曲目：走自建后端拿歌词 ===
		$request->setStatusProcessing();

		# 先查缓存
		my $lyric = $cache->get("netease_lyric_$sid");

		# 缓存 miss → 同步调自建后端
		if ( !$lyric ) {
			require LWP::Simple;
			require JSON::XS;

			my $prefs   = preferences('plugin.netease');
			my $apiBase = $prefs->get('apiBase') || 'http://127.0.0.1:3000';
			my $apiUrl  = "$apiBase/lyric?id=$sid";

			my $content = eval { LWP::Simple::get( $apiUrl, timeout => 8 ) };

			if ( $content ) {
				my $json = eval { JSON::XS::decode_json($content) };

				if ( $json && ref($json) eq 'HASH' && $json->{code} == 200 ) {
					$lyric = {
						lrc    => $json->{lrc}{lyric}    || '',
						tlyric => $json->{tlyric}{lyric} || '',
						klyric => $json->{klyric}{lyric} || '',
					};
					$cache->set( "netease_lyric_$sid", $lyric );
				}
			}
		}

		# 还是没拿到 → 返回空（和 MAI 格式一致：没 lyrics 字段或空字符串）
		if ( !$lyric || !$lyric->{lrc} ) {
			$request->addResult('title', "NetEase track $sid");
			# 不加 lyrics 字段 → Material Skin 显示空
			$request->setStatusDone();
			return;
		}

		# 直接塞 LRC 字符串（和 MAI 原始 handler 格式一致）
		# Material Skin 期望 result.lyrics 是字符串 → 传给 formatLyrics() 解析
		my $lrc_text = $lyric->{lrc} || '';

		# 如果请求没要 timestamps（或有 url 参数说明是电台流），去时间戳只留纯文本
		my $want_ts   = $request->getParam('timestamps') ? 1 : 0;
		my $radio_url = $request->getParam('url') || '';
		if ( !$want_ts || $radio_url =~ m{^https?://} ) {
			# strip LRC timestamps: [mm:ss.xx] 或 [mm:ss]
			$lrc_text =~ s/^\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]\s*//gm;
			$lrc_text =~ s/^\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]\s*//g;
		}

		my $meta = $cache->get("netease_meta_$sid") || {};

		$request->addResult('title',  $meta->{title}  || "NetEase track $sid");
		$request->addResult('artist', $meta->{artist} || 'NetEase');
		$request->addResult('lyrics', $lrc_text) if length($lrc_text);
		$request->setStatusDone();
	};

	# 注册 override，捕获被替换的原函数 ref（undef = 之前没人注册）
	my $replaced = Slim::Control::Request::addDispatch(
		['musicartistinfo', 'lyrics'],
		[0, 1, 1, $netease_lyrics_wrapper],
	);

	# 如果 MAI 还没加载（addDispatch 返回 undef），延迟重试
	if ( !defined($replaced) ) {
		Slim::Utils::Timers::setTimer(
			__PACKAGE__,
			time() + 5,
			sub {
				my $again = Slim::Control::Request::addDispatch(
					['musicartistinfo', 'lyrics'],
					[0, 1, 1, $netease_lyrics_wrapper],
				);
			},
		);
	}

	# 网易云请求判断：参数里 artist_id / album_id / track_id 是 7+ 位纯数字，
	# 或 url 参数里有 netease://
	my $is_request_netease = sub {
		my ($request) = @_;
		for my $p (qw(artist_id album_id work_id track_id)) {
			my $v = $request->getParam($p) || '';
			return 1 if $v =~ m{^\d{7,}$};
		}
		my $url = $request->getParam('url') || '';
		return 1 if $url =~ m{netease://};
		return 0;
	};

	my $empty_return = sub {
		my $request = shift;
		$request->setStatusProcessing();
		$request->addResult('items', []);
		$request->setStatusDone();
	};

	# === 网易云曲目 → 从网易云后端拿艺人/专辑简介 ===
	# Material Skin "Information" tab 调 MAI albumreview/biography。
	# 之前我们直接返回空（避免维基超时），现在改成从自建后端拿：
	#   biography   → /artists?id=<artist_id> → artist.briefDesc
	#   albumreview → /album?id=<album_id>    → album.description
	#   artistphoto/artistphotos/albumcovers/workreview → 继续返回空（不用维基）
	#
	# artist_id / album_id 从 netease_meta_<sid> 缓存里拿，
	# sid 通过查询 LMS status 拿当前播放 track URL 里的网易云 song id。

	# 从 LMS status 查当前网易云曲目 sid
	my $get_current_sid = sub {
		my ($request) = @_;
		my $client = $request->client();
		return unless defined $client;

		my $status = Slim::Control::Request::executeRequest($client, ['status', 0, 2]);
		my $url = '';
		if ( $status->getResult('track') ) {
			$url = $status->getResult('track');
		}
		# track 可能是 OPML item_loop
		if ( !$url && $status->getResult('item_loop') ) {
			my $items = $status->getResult('item_loop');
			if ( ref $items eq 'ARRAY' && @$items ) {
				$url = $items->[0]{url} || '';
			}
		}

		if ( $url =~ m{netease://track/(\d+)} ) {
			return $1;
		}
		if ( $url =~ m{(\d{7,})} ) {
			return $1;
		}
		return;
	};

	# 通用 HTTP 同步请求（简介数据量小，同步没问题）
	my $fetch_backend = sub {
		my ($apiUrl) = @_;
		require LWP::Simple;
		require JSON::XS;
		my $prefs   = preferences('plugin.netease');
		my $apiBase = $prefs->get('apiBase') || 'http://127.0.0.1:3000';
		my $fullUrl = $apiBase . $apiUrl;
		my $content = eval { LWP::Simple::get( $fullUrl, timeout => 8 ) };
		return unless $content;
		my $json = eval { JSON::XS::decode_json($content) };
		return unless $json && ref($json) eq 'HASH' && $json->{code} == 200;
		return $json;
	};

	# 从 song.detail 兜底查 artist_id / album_id（缓存没有时用）
	my $ensure_track_ids = sub {
		my ($sid) = @_;
		return unless $sid;
		my $meta = $cache->get("netease_meta_$sid") || {};
		my $has_artist = ref($meta->{artist_ids}) eq 'ARRAY' && @{ $meta->{artist_ids} || [] };
		my $has_album  = $meta->{album_id};
		return $meta if $has_artist && $has_album;

		my $json = $fetch_backend->("/song/detail?ids=$sid");
		if ( $json && $json->{songs} && @{ $json->{songs} || [] } ) {
			my $t      = $json->{songs}[0];
			my @ids    = map { $_->{id} } @{ $t->{ar} || $t->{artists} || [] };
			my $alb_id = $t->{al}{id} || $t->{album}{id};
			$meta->{artist_ids} = \@ids if @ids;
			$meta->{album_id}   = $alb_id if $alb_id;
			# 回写缓存
			$cache->set("netease_meta_$sid", $meta, 86400);
		}
		return $meta;
	};

	# === 维基命令 override 策略 ===
	# biography / albumreview → 先查网易云后端（幂等，404 就 fallback MAI）
	# workreview / artistphoto / artistphotos / albumcovers → 网易云请求返回空

	# 从 request 里提取网易云 song_id（和 lyrics handler 一致）
	my $extract_song_id = sub {
		my $request = shift;
		my $url     = $request->getParam('url')     || '';
		my $trackId = $request->getParam('track_id') || '';

		if ( $url =~ m{netease://track/(\d+)} ) { return $1; }
		if ( $trackId =~ m{^(\d{7,})$} )      { return $1; }
		if ( $url =~ m{(\d{7,})} )            { return $1; }
		return;
	};

	# 拆分多艺人/专辑名（按逗号、&、/、／、; 分隔）
	my $split_names = sub {
		my ($name) = @_;
		return () unless defined $name;
		my @parts = split /[,，;&／\/]\s*/, $name;
		@parts = map { s{^\s+|\s+$}{}g; $_ } @parts;
		@parts = grep { $_ && length($_) >= 1 } @parts;
		return @parts;
	};

	# 从网易云搜索 API 兜底找 artist_id（单个）
	my $search_artist_id = sub {
		my ($name, $trackTitle) = @_;
		return unless $name;
		my $kw = $trackTitle ? "$name $trackTitle" : $name;
		my $json = $fetch_backend->("/search?keywords=" . URI::Escape::uri_escape_utf8($kw) . "&type=100&limit=3");
		if ( $json && $json->{result} && $json->{result}{artists} && @{ $json->{result}{artists} || [] } ) {
			# 挑艺人名最匹配的（包含关系即可）
			for my $hit ( @{ $json->{result}{artists} } ) {
				return $hit->{id} if index($hit->{name}, $name) >= 0 || index($name, $hit->{name}) >= 0;
			}
			return $json->{result}{artists}[0]{id};
		}
		return;
	};
	my $search_album_id = sub {
		my ($albumName, $artistName) = @_;
		return unless $albumName;
		my $kw = $artistName ? "$albumName $artistName" : $albumName;
		my $json = $fetch_backend->("/search?keywords=" . URI::Escape::uri_escape_utf8($kw) . "&type=10&limit=3");
		if ( $json && $json->{result} && $json->{result}{albums} && @{ $json->{result}{albums} || [] } ) {
			# 挑艺人匹配的
			if ($artistName) {
				for my $hit ( @{ $json->{result}{albums} } ) {
					my @hits = @{ $hit->{artists} || [] };
					for my $a (@hits) {
						return $hit->{id} if index($a->{name}, $artistName) >= 0 || index($artistName, $a->{name}) >= 0;
					}
				}
			}
			return $json->{result}{albums}[0]{id};
		}
		return;
	};

	# 拿单个艺人简介（带缓存）
	my $fetch_bio = sub {
		my ($artistId) = @_;
		return unless $artistId;
		my $cache_key = "netease_bio_$artistId";
		my $bio = $cache->get($cache_key);
		$bio = Encode::decode_utf8($bio) if defined $bio;
		if ( !$bio ) {
			my $json = $fetch_backend->("/artists?id=$artistId");
			if ( $json && $json->{artist} && $json->{artist}{briefDesc} ) {
				$bio = $json->{artist}{briefDesc};
				my $bytes = Encode::encode_utf8($bio);
				$cache->set( $cache_key, $bytes );
			}
		}
		return $bio;
	};

	# biography handler（支持多艺人）
	my $netease_biography_handler = sub {
		my $request = shift;
		$request->setStatusProcessing();

		my @artistIds;

		# 尝试 1: 直接给了 artist_id（可能是逗号分隔多个）
		my $artistIdParam = $request->getParam('artist_id');
		if ($artistIdParam) {
			push @artistIds, split /[,\s]+/, $artistIdParam;
		}

		# 尝试 2: 从 song_id 缓存拿
		if ( !@artistIds ) {
			my $sid = $extract_song_id->($request);
			if ($sid) {
				my $meta = $ensure_track_ids->($sid);
				if ( ref($meta->{artist_ids}) eq 'ARRAY' ) {
					push @artistIds, @{ $meta->{artist_ids} };
				}
			}
		}

		# 尝试 3: 网易云搜索（artist 名字，支持多艺人）
		if ( !@artistIds ) {
			my $artistName = $request->getParam('artist') || '';
			my @names = $split_names->($artistName);
			for my $n (@names) {
				my $aid = $search_artist_id->($n, $request->getParam('title'));
				push @artistIds, $aid if $aid;
			}
		}

		if ( !@artistIds ) {
			my $orig = Plugins::MusicArtistInfo::ArtistInfo->can('getBiographyCLI');
			if ($orig) { return $orig->($request); }
			$request->setStatusDone();
			return;
		}

		# 逐个艺人拿简介（去重）
		my %seen;
		my @bios;
		for my $aid (@artistIds) {
			next if $seen{$aid}++;
			my $b = $fetch_bio->($aid);
			push @bios, $b if $b && length($b) > 0;
		}

		if (@bios) {
			my $combined = join "\n\n---\n\n", @bios;
			$request->addResult('biography', $combined);
			$request->setStatusDone();
			return;
		}

		my $orig = Plugins::MusicArtistInfo::ArtistInfo->can('getBiographyCLI');
		if ($orig) { return $orig->($request); }
		$request->setStatusDone();
	};

	# albumreview handler
	my $netease_albumreview_handler = sub {
		my $request = shift;
		$request->setStatusProcessing();

		my $albumId = $request->getParam('album_id');

		if ( !$albumId ) {
			my $sid = $extract_song_id->($request);
			if ($sid) {
				my $meta = $ensure_track_ids->($sid);
				$albumId = $meta->{album_id} if $meta->{album_id};
			}
		}

		if ( !$albumId ) {
			my $albumName = $request->getParam('album') || '';
			my $artistName = $request->getParam('artist') || '';
			my @names = $split_names->($artistName);
			for my $n (@names) {
				$albumId = $search_album_id->($albumName, $n);
				last if $albumId;
			}
		}

		if ( !$albumId ) {
			my $orig = Plugins::MusicArtistInfo::AlbumInfo->can('getAlbumReviewCLI');
			if ($orig) { return $orig->($request); }
			$request->setStatusDone();
			return;
		}

		my $alb_cache_key = "netease_albdesc_$albumId";
		my $desc = $cache->get($alb_cache_key);
		$desc = Encode::decode_utf8($desc) if defined $desc;

		if ( !$desc ) {
			my $json = $fetch_backend->("/album?id=$albumId");
			if ( $json && $json->{album} && $json->{album}{description} ) {
				$desc = $json->{album}{description};
				my $bytes = Encode::encode_utf8($desc);
				$cache->set( $alb_cache_key, $bytes );
			}
		}

		if ($desc) {
			$request->addResult('albumreview', $desc);
			$request->setStatusDone();
			return;
		}

		my $orig = Plugins::MusicArtistInfo::AlbumInfo->can('getAlbumReviewCLI');
		if ($orig) { return $orig->($request); }
		$request->setStatusDone();
	};

	# 注册 biography / albumreview override
	Slim::Control::Request::addDispatch(
		['musicartistinfo', 'biography'],
		[0, 1, 1, $netease_biography_handler],
	);
	Slim::Control::Request::addDispatch(
		['musicartistinfo', 'albumreview'],
		[0, 1, 1, $netease_albumreview_handler],
	);

	# workreview / artistphoto / artistphotos / albumcovers：网易云请求返回空
	for my $cmd (qw(workreview artistphoto artistphotos albumcovers)) {
		Slim::Control::Request::addDispatch(
			['musicartistinfo', $cmd],
			[0, 1, 1, sub {
				my $request = shift;
				if ( $is_request_netease->($request) ) {
					return $empty_return->($request);
				}
				# 非网易云 → fallback MAI
				my $orig = Plugins::MusicArtistInfo::API->can($cmd)
					|| Plugins::MusicArtistInfo::ArtistInfo->can($cmd)
					|| Plugins::MusicArtistInfo::AlbumInfo->can($cmd)
					|| Plugins::MusicArtistInfo::TrackInfo->can($cmd);
				if ($orig) { return $orig->($request); }
				$request->setStatusBadDispatch();
			}],
		);
	}

	# 注册 TrackInfo infoProvider（Sound X 代理模式下 Material Skin 不走这条链，
	# 但它在 SqueezePlay/iPeng 等 jive 类客户端上仍然有效）
	if ( Slim::Menu::TrackInfo->can('registerInfoProvider') ) {
		Slim::Menu::TrackInfo->registerInfoProvider( netease_lyrics => (
			func => \&_trackinfo_lyric_handler,
		) );
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'netease',
		menu   => 'apps',
		is_app => 1,
	);
}

sub handleFeed {
	my ( $client, $callback ) = @_;

	my @items;
	my $logged_in = Plugins::NetEase::API->isLoggedIn;

	if ($logged_in) {
		my $who = $prefs->get('nickname') || $prefs->get('uid') || '';
		push @items, {
			name => cstring( $client, 'PLUGIN_NETEASE_LOGGED_IN_AS', $who ),
			type => 'text',
		};

		push @items, {
			name  => cstring( $client, 'PLUGIN_NETEASE_DAILY_RECOMMEND' ),
			type  => 'playlist',
			url   => \&dailyFeed,
			image => 'html/images/albums.png',
			jive  => _feed_actions( $client, 'daily' ),
		};

		push @items, {
			name  => cstring( $client, 'PLUGIN_NETEASE_LIKED_SONGS' ),
			type  => 'playlist',
			url   => \&likedFeed,
			image => 'html/images/playlists.png',
			jive  => _feed_actions( $client, 'liked' ),
		};
	}
	else {
		push @items, {
			name => cstring( $client, 'PLUGIN_NETEASE_NOT_LOGGED_IN' ),
			type => 'text',
		};
	}

	# 推荐新歌是公开能力，未登录也保留入口；playlist 类型让界面出现整单播放按钮。
	push @items, {
		name  => cstring( $client, 'PLUGIN_NETEASE_NEW_SONGS' ),
		type  => 'playlist',
		url   => \&newSongsFeed,
		image => 'html/images/albums.png',
		jive  => _feed_actions( $client, 'new' ),
	};

	push @items, {
		name => cstring( $client, 'PLUGIN_NETEASE_SEARCH' ),
		type => 'search',
		url  => \&searchFeed,
	};

	if ($logged_in) {
		push @items, {
			name  => cstring( $client, 'PLUGIN_NETEASE_MY_PLAYLISTS' ),
			type  => 'link',
			url   => \&playlistsFeed,
			image => 'html/images/albums.png',
		};

		push @items, {
			name  => cstring( $client, 'PLUGIN_NETEASE_DOWNLOAD' ),
			type  => 'link',
			url   => \&downloadFeed,
			image => 'html/images/playlists.png',
		};
	}

	$callback->( { items => \@items } );
}

# 给每日推荐/我喜欢的音乐/推荐新歌这类"内置 feed"入口生成条目动作。
# 命令里的 <feed> 是 daily|liked|new，由 CLI 分发到下载器或 savetolocal。
sub _feed_actions {
	my ( $client, $feed ) = @_;

	return {
		actions => {
			neteaseDownload => {
				cmd   => [ 'netease', 'download', 'feed', $feed ],
				title => cstring( $client, 'PLUGIN_NETEASE_ACTION_DL_PLAYLIST' ),
			},
			neteaseSaveLocal => {
				cmd   => [ 'netease', 'savetolocal', 'feed', $feed ],
				title => cstring( $client, 'PLUGIN_NETEASE_ACTION_SAVE_LOCAL' ),
			},
		},
	};
}

# 单个网易云歌单条目的下载 + 存为本地动作。
sub _playlist_actions {
	my ( $client, $playlistId ) = @_;

	return {
		actions => {
			neteaseDownload => {
				cmd   => [ 'netease', 'download', 'playlist', "$playlistId" ],
				title => cstring( $client, 'PLUGIN_NETEASE_ACTION_DL_PLAYLIST' ),
			},
			neteaseSaveLocal => {
				cmd   => [ 'netease', 'savetolocal', 'playlist', "$playlistId" ],
				title => cstring( $client, 'PLUGIN_NETEASE_ACTION_SAVE_LOCAL' ),
			},
		},
	};
}

sub dailyFeed {
	my ( $client, $callback ) = @_;

	Plugins::NetEase::API->getDailySongs(
		sub { _tracks_feed( $client, $callback, shift ) },
		sub { _feed_error( $client, $callback, shift ) },
	);
}

sub likedFeed {
	my ( $client, $callback ) = @_;

	Plugins::NetEase::API->getLikedSongIds(
		sub {
			my $ids   = shift;
			my $total = scalar @$ids;
			my $page  = $prefs->get('likedPageSize') || 300;
			$page = 1000 if $page > 1000;

			# 数量在一页以内时直接展示曲目；超过一页就拆成分页入口。
			if ( $total <= $page ) {
				Plugins::NetEase::API->getLikedSongs(
					sub { _tracks_feed( $client, $callback, shift ) },
					sub { _feed_error( $client, $callback, shift ) },
					0, $total,
				);
				return;
			}

			my @items;

			for ( my $offset = 0; $offset < $total; $offset += $page ) {
				my $from = $offset + 1;
				my $to   = $offset + $page;
				$to = $total if $to > $total;

				push @items, {
					name        => cstring( $client, 'PLUGIN_NETEASE_LIKED_PAGE', $from, $to, $total ),
					type        => 'playlist',
					url         => \&likedPageFeed,
					image       => 'html/images/playlists.png',
					passthrough => [ { offset => $offset, limit => $page } ],
				};
			}

			$callback->( { items => \@items } );
		},
		sub { _feed_error( $client, $callback, shift ) },
	);
}

sub likedPageFeed {
	my ( $client, $callback, $args, @passthrough ) = @_;

	my $info = $passthrough[0] || {};

	Plugins::NetEase::API->getLikedSongs(
		sub { _tracks_feed( $client, $callback, shift ) },
		sub { _feed_error( $client, $callback, shift ) },
		$info->{offset}, $info->{limit},
	);
}

sub newSongsFeed {
	my ( $client, $callback ) = @_;

	Plugins::NetEase::API->getNewSongs(
		sub { _tracks_feed( $client, $callback, shift ) },
		sub { _feed_error( $client, $callback, shift ) },
	);
}

sub searchFeed {
	my ( $client, $callback, $args ) = @_;

	my $keywords = ref($args) eq 'HASH' ? ( $args->{search} || $args->{q} ) : undef;

	unless ( defined $keywords && length $keywords ) {
		$callback->( { items => [ {
			name => cstring( $client, 'PLUGIN_NETEASE_SEARCH_EMPTY' ),
			type => 'text',
		} ] } );
		return;
	}

	Plugins::NetEase::API->searchSongs(
		$keywords,
		sub { _tracks_feed( $client, $callback, shift ) },
		sub { _feed_error( $client, $callback, shift ) },
	);
}

# 把一组曲目渲染成可播放菜单项，供每日推荐/红心/新歌/搜索共用。
sub _tracks_feed {
	my ( $client, $callback, $tracks ) = @_;

	unless ( ref($tracks) eq 'ARRAY' && @$tracks ) {
		$callback->( { items => [ {
			name => cstring( $client, 'PLUGIN_NETEASE_NO_RESULTS' ),
			type => 'text',
		} ] } );
		return;
	}

	if ( @$tracks <= ($prefs->get("precheckLimit") || 300) ) {
		Plugins::NetEase::API->getSongUrls(
			[ map { $_->{id} } @$tracks ],
			sub {
				$callback->( { items => [ _track_items( $client, $tracks, shift ) ] } );
			},
			sub {
				my $err = shift || '';
				$log->warn("Failed to resolve URLs for feed: $err");
				$callback->( { items => [ _track_items( $client, $tracks, {} ) ] } );
			},
		);
	}
	else {
		$callback->( { items => [ _track_items( $client, $tracks, undef ) ] } );
	}
}

sub _feed_error {
	my ( $client, $callback, $err ) = @_;

	$err = '' unless defined $err;

	my $name;

	if ( $err eq 'login_required' ) {
		$name = cstring( $client, 'PLUGIN_NETEASE_LOGIN_REQUIRED' );
	}
	elsif ( $err eq 'unsupported_backend' ) {
		$name = cstring( $client, 'PLUGIN_NETEASE_BACKEND_UNSUPPORTED' );
	}
	elsif ( $err eq 'empty_result' || $err eq 'empty_keyword' ) {
		$name = cstring( $client, 'PLUGIN_NETEASE_NO_RESULTS' );
	}
	else {
		$log->warn("NetEase feed error: $err");
		$name = cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err );
	}

	$callback->( { items => [ { name => $name, type => 'text' } ] } );
}

sub playlistsFeed {
	my ( $client, $callback ) = @_;

	Plugins::NetEase::API->getUserPlaylists(
		sub {
			my $playlists = shift;

			my @items;
			for my $pl ( @$playlists ) {
				next unless $pl->{id};

				my $name  = $pl->{name}  || '';
				my $count = $pl->{trackCount} || 0;

				push @items, {
					name        => cstring( $client, 'PLUGIN_NETEASE_PLAYLIST_ITEM', $name, $count ),
					type        => 'playlist',
					url         => \&playlistFeed,
					image       => _image( $pl->{coverImgUrl} ),
					passthrough => [ {
						id    => $pl->{id},
						name  => $name,
						count => $count,
						cover => $pl->{coverImgUrl},
					} ],
					jive => _playlist_actions( $client, $pl->{id} ),
				};
			}

			@items = ( {
				name => cstring( $client, 'PLUGIN_NETEASE_NO_PLAYLISTS' ),
				type => 'text',
			} ) unless @items;

			$callback->( { items => \@items } );
		},
		sub {
			my $err = shift || '';
			$log->warn("Failed to load playlists: $err");
			$callback->( { items => [ {
				name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err ),
				type => 'text',
			} ] } );
		},
	);
}

sub playlistFeed {
	my ( $client, $callback, $args, @passthrough ) = @_;

	my $info  = $passthrough[0] || {};
	my $id    = $info->{id};
	my $name  = $info->{name} || $id;
	my $count = $info->{count} || 0;

	unless ($id) {
		$callback->( { items => [ {
			name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', 'missing playlist id' ),
			type => 'text',
		} ] } );
		return;
	}

	# 超过一页时只列分页入口，不在这一层加载曲目。
	if ( $count > PLAYLIST_PAGE_SIZE ) {
		my @items;

		for ( my $offset = 0; $offset < $count; $offset += PLAYLIST_PAGE_SIZE ) {
			my $from = $offset + 1;
			my $to   = $offset + PLAYLIST_PAGE_SIZE;
			$to = $count if $to > $count;

			push @items, {
				name        => cstring( $client, 'PLUGIN_NETEASE_PLAYLIST_PAGE', $name, $from, $to, $count ),
				type        => 'playlist',
				url         => \&playlistPageFeed,
				image       => _image( $info->{cover} ) || 'html/images/playlists.png',
				passthrough => [ {
					id    => $id,
					name  => $name,
					count => $count,
					cover => $info->{cover},
					offset => $offset,
					limit  => PLAYLIST_PAGE_SIZE,
				} ],
			};
		}

		# 整单下载放在歌单这一层，避免在每个分页里重复出现。
		push @items, _download_playlist_item( $client, $id, $name );

		$callback->( { items => \@items } );
		return;
	}

	Plugins::NetEase::API->getPlaylistTracks(
		$id,
		sub {
			my $tracks = shift;

			unless ( @$tracks ) {
				$callback->( { items => [ {
					name => cstring( $client, 'PLUGIN_NETEASE_EMPTY_PLAYLIST' ),
					type => 'text',
				} ] } );
				return;
			}

			_playlist_tracks_menu( $client, $callback, $id, $name, $tracks, 1 );
		},
		sub {
			my $err = shift || '';
			$log->warn("Failed to load tracks for playlist $id: $err");
			$callback->( { items => [ {
				name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err ),
				type => 'text',
			} ] } );
		},
	);
}

# 歌单分页入口：只取本页曲目。
sub playlistPageFeed {
	my ( $client, $callback, $args, @passthrough ) = @_;

	my $info = $passthrough[0] || {};
	my $id   = $info->{id};
	my $name = $info->{name} || $id;

	unless ($id) {
		$callback->( { items => [ {
			name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', 'missing playlist id' ),
			type => 'text',
		} ] } );
		return;
	}

	Plugins::NetEase::API->getPlaylistTracks(
		$id,
		sub {
			my $tracks = shift;

			unless ( @$tracks ) {
				$callback->( { items => [ {
					name => cstring( $client, 'PLUGIN_NETEASE_EMPTY_PLAYLIST' ),
					type => 'text',
				} ] } );
				return;
			}

			_playlist_tracks_menu( $client, $callback, $id, $name, $tracks, 0 );
		},
		sub {
			my $err = shift || '';
			$log->warn("Failed to load tracks for playlist $id: $err");
			$callback->( { items => [ {
				name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err ),
				type => 'text',
			} ] } );
		},
		$info->{offset}, $info->{limit},
	);
}

# 把一组歌单曲目渲染成可播放菜单项；$with_download 为真时在末尾附上整单下载入口。
sub _playlist_tracks_menu {
	my ( $client, $callback, $id, $name, $tracks, $with_download ) = @_;

	my $render = sub {
		my $urls = shift;
		my @items = _track_items( $client, $tracks, $urls );
		push @items, _download_playlist_item( $client, $id, $name ) if $with_download;
		$callback->( { items => \@items } );
	};

	# 曲目数量不多时批量解析 URL，用于在菜单里明确标注不可播放的曲目。
	if ( @$tracks <= ($prefs->get("precheckLimit") || 300) ) {
		Plugins::NetEase::API->getSongUrls(
			[ map { $_->{id} } @$tracks ],
			sub { $render->( shift ) },
			sub {
				my $err = shift || '';
				$log->warn("Failed to resolve URLs for playlist $id: $err");
				$render->( {} );
			},
		);
	}
	else {
		$render->( undef );
	}
}

sub _track_items {
	my ( $client, $tracks, $urls ) = @_;

	my @items;

	for my $t ( @$tracks ) {
		my $id       = $t->{id};
		my $title    = $t->{name} || '';
		my $artist   = _artist( $t->{artist} );
		my $cover    = _image( $t->{cover} );
		my $duration = $t->{duration} || 0;
		my $label    = $artist ? "$artist - $title" : $title;

		my $u = $urls ? $urls->{$id} : undef;

		# $urls 为 undef 表示曲目过多、未做预检查；仍交给播放时解析。
		if ( $urls && ( !$u || !$u->{url} ) ) {
			my $reason = _reason_text( $client, $u ? $u->{reason} : 'url_empty' );
			my $name   = cstring( $client, 'PLUGIN_NETEASE_UNPLAYABLE_ITEM', $label, $reason );
			push @items, {
				name  => $name,
				type  => 'text',
				image => $cover || 'html/images/albums.png',
			};
			next;
		}

		if ( $u && $u->{freeTrialInfo} ) {
			$label .= ' ' . cstring( $client, 'PLUGIN_NETEASE_TRIAL_ONLY' );
		}

		push @items, {
			name     => $label,
			type     => 'audio',
			url      => "netease://track/$id",
			play     => "netease://track/$id",
			image    => $cover || 'html/images/albums.png',
			duration => $duration,
			passthrough => [ { songId => $id } ],
			# 条目级动作：由 Slim::Control::XMLBrowser 合并进条目的 actions，
			# 命令复用已注册的 CLI（netease download track <id>）。
			jive => {
				actions => {
					neteaseDownload => {
						cmd   => [ 'netease', 'download', 'track', "$id" ],
						title => cstring( $client, 'PLUGIN_NETEASE_ACTION_DL_TRACK' ),
					},
				},
			},
		};

		# 缓存元数据，供 ProtocolHandler 的 getMetadataFor 和维基 override handler 使用。
		$cache->set(
			"netease_meta_$id",
			{
				title      => $title,
				artist     => $artist,
				album      => $t->{album} || '',
				album_id   => $t->{album_id},
				artist_ids => $t->{artist_ids} || [],
				cover      => $cover,
				duration   => $duration,
			},
			86400,
		);
	}

	return @items;
}

sub _download_playlist_item {
	my ( $client, $id, $name ) = @_;

	return {
		name  => cstring( $client, 'PLUGIN_NETEASE_DOWNLOAD_PLAYLIST' ),
		type  => 'link',
		image => 'html/images/playlists.png',
		url   => sub {
			my ( $c, $cb ) = @_;

			Plugins::NetEase::Downloader->downloadPlaylist( $id, $name );

			$cb->( { items => [ {
				name => cstring( $c, 'PLUGIN_NETEASE_DOWNLOAD_STARTED' ),
				type => 'text',
			} ] } );
		},
	};
}

sub downloadFeed {
	my ( $client, $callback ) = @_;

	Plugins::NetEase::API->getUserPlaylists(
		sub {
			my $playlists = shift;

			my @items;
			for my $pl ( @$playlists ) {
				next unless $pl->{id};

				my $name  = $pl->{name} || '';
				my $count = $pl->{trackCount} || 0;

				push @items, {
					name  => cstring( $client, 'PLUGIN_NETEASE_PLAYLIST_ITEM', $name, $count ),
					type  => 'link',
					url   => \&downloadPlaylistFeed,
					image => _image( $pl->{coverImgUrl} ),
					passthrough => [ {
						id   => $pl->{id},
						name => $name,
					} ],
				};
			}

			@items = ( {
				name => cstring( $client, 'PLUGIN_NETEASE_NO_PLAYLISTS' ),
				type => 'text',
			} ) unless @items;

			$callback->( { items => \@items } );
		},
		sub {
			my $err = shift || '';
			$log->warn("Failed to load playlists for download: $err");
			$callback->( { items => [ {
				name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err ),
				type => 'text',
			} ] } );
		},
	);
}

sub downloadPlaylistFeed {
	my ( $client, $callback, $args, @passthrough ) = @_;

	my $info = $passthrough[0] || {};
	my $id   = $info->{id};
	my $name = $info->{name} || $id;

	unless ($id) {
		$callback->( { items => [ {
			name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', 'missing playlist id' ),
			type => 'text',
		} ] } );
		return;
	}

	Plugins::NetEase::API->getAllPlaylistTracks(
		$id,
		sub {
			my $tracks = shift;

			unless ( @$tracks ) {
				$callback->( { items => [ {
					name => cstring( $client, 'PLUGIN_NETEASE_EMPTY_PLAYLIST' ),
					type => 'text',
				} ] } );
				return;
			}

			# 整张歌单下载仍保留，但放在最前面，方便选择后立即执行。
			my @items = ( _download_playlist_item( $client, $id, $name ) );

			# 每首曲目单独一项，点击即只下载该曲，避免误触发整张歌单。
			for my $t ( @$tracks ) {
				my $songId = $t->{id};
				next unless $songId;

				my $title  = $t->{name} || '';
				my $artist = _artist( $t->{artist} );
				my $label  = $artist ? "$artist - $title" : $title;

				push @items, {
					name  => cstring( $client, 'PLUGIN_NETEASE_DOWNLOAD_TRACK_ITEM', $label ),
					type  => 'link',
					image => _image( $t->{cover} ) || 'html/images/albums.png',
					url   => sub {
						my ( $c, $cb ) = @_;

						Plugins::NetEase::Downloader->downloadTrack( $songId );

						$cb->( { items => [ {
							name => cstring( $c, 'PLUGIN_NETEASE_DOWNLOAD_STARTED' ),
							type => 'text',
						} ] } );
					},
				};
			}

			$callback->( { items => \@items } );
		},
		sub {
			my $err = shift || '';
			$log->warn("Failed to load tracks for download playlist $id: $err");
			$callback->( { items => [ {
				name => cstring( $client, 'PLUGIN_NETEASE_LOAD_FAILED', $err ),
				type => 'text',
			} ] } );
		},
	);
}

sub cliDownload {
	my $request = shift;

	my $what = $request->getParam('_what');
	my $id   = $request->getParam('_id');

	if ( $what && $what eq 'all' ) {
		Plugins::NetEase::Downloader->downloadAll;
	}
	elsif ( $what && $what eq 'playlist' && defined $id && length $id ) {
		Plugins::NetEase::Downloader->downloadPlaylist( $id, undef );
	}
	elsif ( $what && $what eq 'track' && defined $id && length $id ) {
		Plugins::NetEase::Downloader->downloadTrack( $id );
	}
	elsif ( $what && $what eq 'feed' && defined $id && length $id ) {
		Plugins::NetEase::Downloader->downloadFeed( $id );
	}
	else {
		$request->addResult( 'message', 'usage: netease download all|playlist|track|feed <id>' );
		$request->setStatusBadParams;
		return;
	}

	$request->addResult( 'message', 'download queued' );
	$request->setStatusDone;
}

sub cliLyrics {
	my $request = shift;

	my $id = $request->getParam('_id');

	unless ( defined $id && length $id ) {
		$request->addResult( 'message', 'usage: netease lyrics <trackId>' );
		$request->setStatusBadParams;
		return;
	}

	my $cache_key = "netease_lyric_$id";

	# 缓存命中：直接同步返回，Material Skin / CLI 都能立刻拿到。
	if ( my $cached = $cache->get($cache_key) ) {
		$request->addResult( 'lrc',    $cached->{lrc}    || '' );
		$request->addResult( 'tlyric', $cached->{tlyric} || '' );
		$request->addResult( 'klyric', $cached->{klyric} || '' );
		$request->addResult( 'nolyric',   $cached->{nolyric}   || 0 );
		$request->addResult( 'pureMusic', $cached->{pureMusic} || 0 );
		$request->setStatusDone;
		return;
	}

	# 缓存未命中：启动异步拉取 + 缓存，先返回 queued，下一次调用就能拿到。
	# Material Skin 前端可以等 metadata 变化后再调一次，或直接等 ProtocolHandler
	# 塞到 track metadata 里。
	_prime_lyric_cache($id);

	$request->addResult( 'message', 'lyric queued' );
	$request->setStatusDone;
}

# 异步拉取单个曲目歌词并写入缓存。播放时 / 进入歌单时 / CLI miss 时调用。
sub _prime_lyric_cache {
	my ($id) = @_;

	require Plugins::NetEase::API;

	Plugins::NetEase::API->getSongLyric(
		$id,
		sub {
			my $lyrics = shift;
			$cache->set( "netease_lyric_$id", $lyrics );
			$log->debug("lyric cache primed for $id");
		},
		sub {
			my $err = shift || 'unknown';
			$log->debug("lyric cache miss for $id: $err");
		},
	);
}

# Slim::Menu::TrackInfo infoProvider 回调。Material Skin "正在播放"页调 TrackInfo
# 菜单时会遍历所有 infoProvider，我们检测 URL 是不是 netease://track/* 然后返回
# 歌词 tab 入口。仿 MAI 的 TrackInfo.pm:_objInfoHandler。
sub _trackinfo_lyric_handler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	return unless $url && $url =~ m{^netease://track/(\d+)};
	my $sid = $1;

	$log->info("netease lyric handler matched track id=$sid");

	# 缓存命中时直接返回，Material Skin 同步拿到 tab。
	if ( my $lyric = $cache->get("netease_lyric_$sid") ) {
		return {
			name        => cstring( $client, 'PLUGIN_NETEASE_TRACK_LYRIC' ),
			type        => 'link',
			url         => \&_trackinfo_lyric_feed,
			passthrough => [ { id => $sid } ],
		};
	}

	# 缓存未命中：异步预热 + 仍然返回 tab 入口。Material Skin 调 feed 时
	# 如果还没预热完会返回 "歌词加载中..."，但 ProtocolHandler.scanUrl
	# 播放时会自动预热，通常几秒内就有缓存。
	$log->info("netease lyric cache miss for id=$sid, queuing prime");
	_prime_lyric_cache($sid);

	return {
		name        => cstring( $client, 'PLUGIN_NETEASE_TRACK_LYRIC' ),
		type        => 'link',
		url         => \&_trackinfo_lyric_feed,
		passthrough => [ { id => $sid } ],
	};
}

# TrackInfo 菜单的 feed 回调——返回歌词文本。格式仿 MAI 的 TrackInfo.pm:getLyrics。
sub _trackinfo_lyric_feed {
	my ( $client, $callback, $args, @passthrough ) = @_;

	my $info = $passthrough[0] || {};
	my $sid  = $info->{id};

	unless ($sid) {
		$callback->( { items => [ { name => '歌词加载失败', type => 'text' } ] } );
		return;
	}

	if ( my $lyric = $cache->get("netease_lyric_$sid") ) {
		# 格式化：LRC 原文（带时间轴）+ 可选翻译，合并显示。
		my @lines;
		push @lines, $lyric->{lrc} if $lyric->{lrc};
		if ( $lyric->{tlyric} ) {
			push @lines, '', '---', '', $lyric->{tlyric};
		}
		my $text = join( "\n", @lines );

		# LMS 菜单系统里，歌词用 type => 'text' 或 type => 'link' + url。
		# Material Skin "正在播放"页对 TrackInfo feed 直接渲染文本。
		my @items;
		for my $line ( split /\n/, $text ) {
			push @items, {
				name => $line,
				type => 'text',
			};
		}
		$callback->( { items => \@items } );
		return;
	}

	# 缓存还没好——触发一次拉取，但 Material Skin 这次可能就看不到了。
	_prime_lyric_cache($sid);
	$callback->( { items => [ {
		name => cstring( $client, 'PLUGIN_NETEASE_LYRIC_LOADING' ),
		type => 'text',
	} ] } );
}

sub cliSaveToLocal {
	my $request = shift;

	my $what = $request->getParam('_what');
	my $id   = $request->getParam('_id');

	unless ( defined $what && length $what ) {
		$request->addResult( 'message', 'usage: netease savetolocal playlist|feed <id>' );
		$request->setStatusBadParams;
		return;
	}

	my $client = $request->client();
	unless ($client) {
		$request->addResult( 'message', 'savetolocal requires a connected player' );
		$request->setStatusBadParams;
		return;
	}

	# 异步触发：API 调用全是回调链，不能在同步 CLI 请求里等结果。
	# 用一个短延迟让事件循环先返回，再启动拉取流程。
	my $p = $client;   # 持有引用避免 client 被 GC
	my $w;             # 先声明再赋值，让匿名 sub 能引用自己
	$w = AnyEvent->timer( after => 0.05, cb => sub {
		Plugins::NetEase::Plugin->_savetolocal( $p, $what, $id );
		undef $w;
	} );

	$request->addResult( 'message', 'save queued' );
	$request->setStatusDone;
}

# 真正的保存逻辑：纯异步，在事件循环的下一个 tick 里执行。
# 先拉曲目，拿到 URL 列表后再存为本地 playlist。
sub _savetolocal {
	my ( $class, $client, $what, $id ) = @_;

	require Plugins::NetEase::API;
	require Slim::Player::Playlist;

	my @urls;
	my $playlist_name;

	my $after_urls = sub {
		return unless @urls;
		$class->_save_urls_as_local_playlist( $client, \@urls, $playlist_name );
	};

	my $on_err = sub {
		my $err = shift || 'unknown';
		$log->warn("savetolocal: failed to load $what ($id): $err");
	};

	if ( $what eq 'playlist' ) {
		$playlist_name = "网易云歌单 $id";
		Plugins::NetEase::API->getAllPlaylistTracks(
			$id,
			sub {
				my $tracks = shift;
				return $on_err->('empty playlist') unless @$tracks;
				@urls = map { "netease://track/$_->{id}" } @$tracks;
				$after_urls->();
			},
			$on_err,
		);
	}
	elsif ( $what eq 'feed' ) {
		my %names = (
			daily => '网易云 - 每日推荐',
			liked => '网易云 - 我喜欢的音乐',
			new   => '网易云 - 推荐新歌',
		);
		return $on_err->("unknown feed: $id") unless exists $names{$id};

		$playlist_name = $names{$id};

		if ( $id eq 'liked' ) {
			# 按页拉，每页 300。
			my $offset = 0;
			my @all;
			my $step;
			$step = sub {
				Plugins::NetEase::API->getLikedSongs(
					sub {
						my ( $page, $total ) = @_;
						$page ||= [];
						push @all, @$page;
						$offset += 300;
						if ( @$page && $offset < ( $total || 0 ) ) {
							$step->();
						}
						else {
							return $on_err->('empty liked') unless @all;
							@urls = map { "netease://track/$_->{id}" } @all;
							$after_urls->();
						}
					},
					$on_err,
					$offset,
					300,
				);
			};
			$step->();
		}
		else {
			my $method = $id eq 'daily' ? 'getDailySongs' : 'getNewSongs';
			Plugins::NetEase::API->$method(
				sub {
					my $tracks = shift || [];
					return $on_err->("empty feed $id") unless @$tracks;
					@urls = map { "netease://track/$_->{id}" } @$tracks;
					$after_urls->();
				},
				$on_err,
			);
		}
	}
	else {
		$on_err->("unsupported: $what");
	}
}

# 已经拿到 netease://track/<id> URL 数组后，存进 LMS 本地 playlist。
# 流程：保存当前播放队列 → 清空 → addtracks listRef → save → 恢复原队列。
# 全走官方 CLI，不碰 Schema 内部。
sub _save_urls_as_local_playlist {
	my ( $class, $client, $urls, $name ) = @_;

	require Slim::Player::Playlist;

	unless ( ref($urls) eq 'ARRAY' && @$urls ) {
		$log->warn("savetolocal: empty track list for '$name'");
		return;
	}

	my $safe_name = Slim::Utils::Misc::cleanupFilename($name);

	# 保存当前队列，操作完恢复。
	my @orig_queue = Slim::Player::Playlist::playList($client);

	# 同名 playlist 已存在时，在名称后加时间戳避免覆盖。
	if ( my $dir = Slim::Utils::Misc::getPlaylistDir() ) {
		my $file = catfile( $dir, Slim::Utils::Unicode::encode_locale($safe_name) . '.m3u' );
		if ( -e $file ) {
			my $stamp = strftime( '%Y%m%d-%H%M%S', localtime() );
			$safe_name .= " ($stamp)";
		}
	}

	# 顺序执行：清空 → 加入 → 保存 → 恢复。
	$client->execute( ['playlist', 'clear'] );
	$client->execute( [ 'playlist', 'addtracks', 'listRef', $urls ] );
	my $save = $client->execute( [ 'playlist', 'save', "_title=$safe_name", 'silent=1' ] );
	my $saved_id = ref($save) eq 'HASH' ? $save->{__playlist_id} : undef;

	# 恢复原播放队列。
	if (@orig_queue) {
		$client->execute( ['playlist', 'clear'] );
		my @orig_urls = map {
			ref($_) && $_->can('urlFor') ? $_->urlFor() : "$_"
		} @orig_queue;
		$client->execute( [ 'playlist', 'addtracks', 'listRef', \@orig_urls ] );
	}

	if ($saved_id) {
		$log->info("savetolocal: '$name' -> local playlist id $saved_id ($safe_name.m3u, " . scalar(@$urls) . " tracks)");
	}
	else {
		$log->warn("savetolocal: playlist save did not return id for '$name'");
	}
}

sub _artist {
	my $artists = shift;

	return '' unless ref($artists) eq 'ARRAY' && @$artists;

	my @names = grep { defined $_ && length $_ } map { $_->{name} } @$artists;
	return join( ', ', @names );
}

sub _image {
	my $url = shift;

	return undef unless defined $url && length $url;

	# 网易云 CDN 同时支持 https，避免 LMS 使用 https 时的混合内容问题。
	$url =~ s{^http://}{https://};

	return $url;
}

sub _reason_text {
	my ( $client, $reason ) = @_;

	my %token = (
		vip       => 'PLUGIN_NETEASE_REASON_VIP',
		auth      => 'PLUGIN_NETEASE_REASON_AUTH',
		copyright => 'PLUGIN_NETEASE_REASON_COPYRIGHT',
		trial     => 'PLUGIN_NETEASE_REASON_TRIAL',
		url_empty => 'PLUGIN_NETEASE_REASON_URL_EMPTY',
		not_found => 'PLUGIN_NETEASE_REASON_NOT_FOUND',
	);

	my $key = $token{ $reason || '' } || 'PLUGIN_NETEASE_REASON_UNKNOWN';

	return cstring( $client, $key );
}

1;

__END__

=head1 NAME

Plugins::NetEase::Plugin - 网易云音乐 LMS 插件

=head1 DESCRIPTION

把网易云音乐账号下的歌单接入 Lyrion Music Server 的浏览菜单，并通过
C<netease://> 协议处理器实现在线播放。

=cut

