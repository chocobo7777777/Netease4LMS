package Plugins::NetEase::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

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
		};

		push @items, {
			name  => cstring( $client, 'PLUGIN_NETEASE_LIKED_SONGS' ),
			type  => 'playlist',
			url   => \&likedFeed,
			image => 'html/images/playlists.png',
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

			# 数量在一页以内时直接展示曲目；超过一页就拆成分页入口。
			if ( $total <= LIKED_PAGE_SIZE ) {
				Plugins::NetEase::API->getLikedSongs(
					sub { _tracks_feed( $client, $callback, shift ) },
					sub { _feed_error( $client, $callback, shift ) },
					0, $total,
				);
				return;
			}

			my @items;

			for ( my $offset = 0; $offset < $total; $offset += LIKED_PAGE_SIZE ) {
				my $from = $offset + 1;
				my $to   = $offset + LIKED_PAGE_SIZE;
				$to = $total if $to > $total;

				push @items, {
					name        => cstring( $client, 'PLUGIN_NETEASE_LIKED_PAGE', $from, $to, $total ),
					type        => 'playlist',
					url         => \&likedPageFeed,
					image       => 'html/images/playlists.png',
					passthrough => [ { offset => $offset, limit => LIKED_PAGE_SIZE } ],
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

	if ( @$tracks <= MAX_PRECHECK_TRACKS ) {
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
	if ( @$tracks <= MAX_PRECHECK_TRACKS ) {
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
		};

		# 缓存元数据，供 ProtocolHandler 的 getMetadataFor 使用。
		$cache->set(
			"netease_meta_$id",
			{
				title    => $title,
				artist   => $artist,
				album    => $t->{album} || '',
				cover    => $cover,
				duration => $duration,
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
	else {
		$request->addResult( 'message', 'usage: netease download all|playlist|track <id>' );
		$request->setStatusBadParams;
		return;
	}

	$request->addResult( 'message', 'download queued' );
	$request->setStatusDone;
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
