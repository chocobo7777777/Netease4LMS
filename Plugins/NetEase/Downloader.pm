package Plugins::NetEase::Downloader;

use strict;

use File::Path qw(mkpath);
use File::Spec;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.netease');
my $prefs = preferences('plugin.netease');

my $UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
	. '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

# 设置页目录下拉框最多列出的候选数量；其余目录仍可通过输入/自动补全选择。
use constant MAX_DIR_CHOICES => 40;

# 监控页保留的历史任务数量与每个任务记录的错误条数。
use constant MAX_HISTORY    => 30;
use constant MAX_JOB_ERRORS => 8;

my @pending;   # 排队中的任务
my $current;   # 正在执行的任务（hashref）
my @history;   # 已结束的任务，最新在前
my $jobSeq = 0;

sub downloadAll {
	my ( $class, $done ) = @_;

	$done ||= sub {};

	_enqueue( 'all', '', sub {
		my $next = shift;

		require Plugins::NetEase::API;

		Plugins::NetEase::API->getUserPlaylists(
			sub {
				my $playlists = shift;

				unless ( @$playlists ) {
					$log->info('NetEase download: no playlists found');
					_job_message('no playlists found for this account');
					$next->();
					return;
				}

				my $index = 0;
				my $step;
				$step = sub {
					if ( $index >= @$playlists || _cancelled() ) {
						$next->();
						return;
					}

					my $pl = $playlists->[ $index++ ];
					$class->_run_playlist( $pl->{id}, $pl->{name}, $step );
				};

				$step->();
			},
			sub {
				my $err = shift || 'unknown error';
				$log->warn("NetEase download: failed to load playlists: $err");
				_job_error("load playlists failed: $err");
				$next->();
			},
		);
	} );
}

sub downloadPlaylist {
	my ( $class, $playlistId, $playlistName, $done ) = @_;

	$done ||= sub {};

	my $label = ( defined $playlistName && length $playlistName )
		? $playlistName
		: "playlist $playlistId";

	_enqueue( 'playlist', $label, sub {
		my $next = shift;
		$class->_run_playlist( $playlistId, $playlistName, sub {
			$next->();
			$done->();
		} );
	} );
}

sub downloadTrack {
	my ( $class, $songId, $done ) = @_;

	$done ||= sub {};

	_enqueue( 'track', "track $songId", sub {
		my $next = shift;
		$class->_run_track( $songId, sub {
			$next->();
			$done->();
		} );
	} );
}

# 监控页用：当前任务、排队任务、历史任务的快照（不含闭包）。
sub queueStatus {
	return {
		current => $current ? _snapshot($current) : undef,
		pending => [ map { _snapshot($_) } @pending ],
		history => [ map { _snapshot($_) } @history ],
	};
}

# 取消任务：排队中的直接移除；正在执行的打标记，当前这首下完后停止。
sub cancelJob {
	my ( $class, $id ) = @_;

	return 0 unless defined $id && $id =~ /^\d+$/;

	if ( $current && $current->{id} == $id ) {
		$current->{cancel} = 1;
		$log->info("NetEase download: cancel requested for job $id");
		return 1;
	}

	my $before = scalar @pending;
	@pending = grep { $_->{id} != $id } @pending;

	if ( @pending != $before ) {
		$log->info("NetEase download: removed queued job $id");
		return 1;
	}

	return 0;
}

sub clearHistory {
	@history = ();
}

sub effectiveDir {
	my $configured = $prefs->get('downloadDir');

	if ( defined $configured ) {
		$configured =~ s{^\s+|\s+$}{}g;
		return $configured if length $configured;
	}

	my $musicFolder = preferences('server')->get('musicfolder');
	$musicFolder = $musicFolder->[0] if ref($musicFolder) eq 'ARRAY';

	if ( defined $musicFolder && length $musicFolder && -d $musicFolder ) {
		return File::Spec->catdir( $musicFolder, 'NetEase' );
	}

	return undef;
}

# 给设置页的目录下拉框用：当前配置目录、音乐库目录及其一级子目录。
# 只是候选值，用户仍可以在输入框里手填或通过 LMS 的自动补全选择任意目录。
sub listDirs {
	my $class = shift;

	my ( @roots, %seen_root );

	my $add_root = sub {
		my $dir = shift;

		return unless defined $dir;

		$dir = "$dir";
		$dir =~ s{^\s+|\s+$}{}g;

		return unless length $dir;
		return if $seen_root{$dir}++;
		return unless -d $dir;

		push @roots, $dir;
	};

	$add_root->( $prefs->get('downloadDir') );

	my $musicFolder = preferences('server')->get('musicfolder');
	$musicFolder = [$musicFolder] unless ref($musicFolder) eq 'ARRAY';
	$add_root->($_) for @$musicFolder;

	$add_root->($_) for qw(/music /musicDownload);

	my ( @dirs, %seen );

	for my $root (@roots) {
		next if $seen{$root}++;
		push @dirs, $root;

		opendir( my $dh, $root ) or next;
		my @subs = sort grep {
			!/^\./ && -d File::Spec->catdir( $root, $_ )
		} readdir($dh);
		closedir $dh;

		for my $sub (@subs) {
			my $dir = File::Spec->catdir( $root, $sub );
			next if $seen{$dir}++;
			push @dirs, $dir;
			last if @dirs >= MAX_DIR_CHOICES;
		}

		last if @dirs >= MAX_DIR_CHOICES;
	}

	return @dirs;
}

# 下载目录诊断：真正尝试建一个临时文件，比 -w 权限位更能反映实际情况
# （只读挂载、ACL、NFS/CIFS 的 root-squash 都会让 -w 判定与实际写入不一致）。
sub checkDownloadDir {
	my $class = shift;

	my $dir = effectiveDir();

	my %info = (
		dir      => $dir,
		exists   => 0,
		writable => 0,
		created  => 0,
		bits     => 0,      # -w 的结论，仅作对比参考
		euid     => $>,
		uid      => $<,
		user     => _account_name( $> ),
		owner    => '',
		mode     => '',
		probe    => '',
	);

	return \%info unless defined $dir;

	unless ( -d $dir ) {
		eval { mkpath($dir) };

		unless ( -d $dir ) {
			$info{probe} = 'missing';
			return \%info;
		}

		$info{created} = 1;
	}

	$info{exists} = 1;
	$info{bits}   = -w $dir ? 1 : 0;

	if ( my @st = stat($dir) ) {
		$info{mode}  = sprintf( '%04o', $st[2] & 07777 );
		$info{owner} = _account_name( $st[4] ) . ':' . _group_name( $st[5] );
	}

	my $tmp = File::Spec->catfile( $dir, ".netease-write-test-$$-" . int( rand(10000) ) );

	if ( open( my $fh, '>', $tmp ) ) {
		print $fh "ok\n";
		close $fh;
		unlink $tmp;
		$info{writable} = 1;
	}
	else {
		$info{probe} = 'write_failed';
	}

	return \%info;
}

sub _account_name {
	my $uid = shift;

	my $name = eval { getpwuid($uid) };

	return defined $name ? $name : "uid $uid";
}

sub _group_name {
	my $gid = shift;

	my $name = eval { getgrgid($gid) };

	return defined $name ? $name : "gid $gid";
}

sub _enqueue {
	my ( $type, $label, $job ) = @_;

	push @pending, {
		id         => ++$jobSeq,
		type       => $type,
		label      => $label || '',
		status     => 'queued',
		queuedAt   => time(),
		startedAt  => 0,
		finishedAt => 0,
		total      => 0,
		processed  => 0,
		saved      => 0,
		skipped    => 0,
		failed     => 0,
		current    => '',
		cancel     => 0,
		crashed    => 0,
		errors     => [],
		job        => $job,
	};

	_start_next();
}

sub _start_next {
	return if $current;

	my $item = shift @pending;

	unless ($item) {
		return;
	}

	$current = $item;
	$item->{status}    = 'running';
	$item->{startedAt} = time();

	my $finished = 0;
	my $next = sub {
		return if $finished;
		$finished = 1;

		$item->{status} = $item->{crashed} ? 'error'
			: $item->{cancel} ? 'cancelled'
			: ( $item->{failed} && !$item->{saved} && !$item->{skipped} ) ? 'error'
			: 'done';
		$item->{finishedAt} = time();
		$item->{current}    = '';
		$current = undef;

		unshift @history, $item;
		pop @history while @history > MAX_HISTORY;

		_start_next();
	};

	eval {
		$item->{job}->($next);
	};

	if ($@) {
		$log->error( 'NetEase download job failed: ' . $@ );
		_job_error($@);
		$item->{crashed} = 1;
		$next->();
	}
}

sub _snapshot {
	my $j = shift;

	return {
		map { $_ => $j->{$_} } qw(
			id type label status queuedAt startedAt finishedAt
			total processed saved skipped failed current cancel
		),
		errors => [ @{ $j->{errors} } ],
	};
}

sub _cancelled {
	return $current && $current->{cancel} ? 1 : 0;
}

sub _job_update {
	my %fields = @_;

	return unless $current;

	while ( my ( $k, $v ) = each %fields ) {
		$current->{$k} = $v;
	}
}

sub _job_bump {
	my $field = shift;

	return unless $current;

	$current->{processed}++;
	$current->{$field}++ if $field;
}

sub _job_message {
	my $msg = shift;

	return unless $current;

	$msg = "$msg";
	$msg =~ s/\s+$//;
	$msg = substr( $msg, 0, 200 ) if length($msg) > 200;

	push @{ $current->{errors} }, $msg;
	shift @{ $current->{errors} } while @{ $current->{errors} } > MAX_JOB_ERRORS;
}

# 与 _job_message 相同，语义上区分错误与普通提示；目前展示上不作区分。
sub _job_error {
	_job_message(@_);
}

sub _run_playlist {
	my ( $class, $playlistId, $playlistName, $done ) = @_;

	$done ||= sub {};

	require Plugins::NetEase::API;

	my $title = ( defined $playlistName && length $playlistName )
		? $playlistName
		: "playlist $playlistId";

	_job_update( current => $title );

	# 整单下载按页拉全量，避免歌单超过 1000 首时只下到前 1000 首。
	Plugins::NetEase::API->getAllPlaylistTracks(
		$playlistId,
		sub {
			my $tracks = shift;

			unless ( @$tracks ) {
				$log->info("NetEase download: playlist $playlistId is empty");
				_job_message("$title: playlist is empty");
				$done->();
				return;
			}

			# 整张下载时 total 会跨歌单累加。
			_job_update( total => ( $current ? $current->{total} : 0 ) + scalar(@$tracks) );

			my @ids = map { $_->{id} } @$tracks;

			Plugins::NetEase::API->getSongUrls(
				\@ids,
				sub {
					my $urls = shift;

					my $dir = _playlist_dir($title);

					unless ($dir) {
						$log->warn('NetEase download: no download directory configured');
						_job_error('no download directory configured or directory not writable');
						$done->();
						return;
					}

					$log->info("NetEase download: playlist $playlistId -> $dir");

					_process_tracks( $tracks, $urls, $dir, $done );
				},
				sub {
					my $err = shift || 'unknown error';
					$log->warn("NetEase download: failed to resolve song URLs for playlist $playlistId: $err");
					_job_error("$title: failed to resolve song URLs: $err");
					$done->();
				},
				$prefs->get('downloadQuality'),
			);
		},
		sub {
			my $err = shift || 'unknown error';
			$log->warn("NetEase download: failed to load playlist $playlistId: $err");
			_job_error("$title: failed to load playlist: $err");
			$done->();
		},
	);
}

sub _run_track {
	my ( $class, $songId, $done ) = @_;

	$done ||= sub {};

	require Plugins::NetEase::API;

	_job_update( total => 1 );

	Plugins::NetEase::API->getSongDetails(
		[$songId],
		sub {
			my $tracks = shift;
			my $track  = $tracks->[0];

			unless ($track) {
				$log->warn("NetEase download: track $songId not found");
				_job_error("track $songId not found");
				_job_bump('failed');
				$done->();
				return;
			}

			_job_update(
				label   => _track_label($track),
				total   => 1,
				current => _track_label($track),
			);

			Plugins::NetEase::API->getSongUrl(
				$songId,
				sub {
					my $u = shift;

					if ( $u && $u->{freeTrialInfo} ) {
						$log->info("NetEase download: track $songId is trial only, skipped");
						_job_message( _track_label($track) . ': trial clip only, skipped' );
						_job_bump('skipped');
						$done->();
						return;
					}

					unless ( $u && defined $u->{url} && length $u->{url} ) {
						my $reason = ( $u && $u->{reason} ) || 'unknown';
						$log->info("NetEase download: track $songId is not downloadable ($reason)");
						_job_message( _track_label($track) . ": not downloadable ($reason)" );
						_job_bump('skipped');
						$done->();
						return;
					}

					my $dir = _playlist_dir('Singles');

					unless ($dir) {
						$log->warn('NetEase download: no download directory configured');
						_job_error('no download directory configured or directory not writable');
						$done->();
						return;
					}

					my $path = File::Spec->catfile( $dir, _filename( $track, $u->{url} ) );

					if ( -e $path && -s $path ) {
						$log->info("NetEase download: already exists, skipped $path");
						_job_bump('skipped');
						$done->();
						return;
					}

					_download_file( $u->{url}, $path, 1, sub {
						my $ok = shift;
						_job_bump( $ok ? 'saved' : 'failed' );
						$done->();
					} );
				},
				sub {
					my $err = shift || 'unknown error';
					$log->warn("NetEase download: failed to resolve track $songId: $err");
					_job_error("track $songId: failed to resolve URL: $err");
					_job_bump('failed');
					$done->();
				},
				$prefs->get('downloadQuality'),
			);
		},
		sub {
			my $err = shift || 'unknown error';
			$log->warn("NetEase download: failed to load track $songId: $err");
			_job_error("track $songId: failed to load details: $err");
			_job_bump('failed');
			$done->();
		},
	);
}

sub _process_tracks {
	my ( $tracks, $urls, $dir, $done ) = @_;

	my $index = 0;
	my $step;

	$step = sub {
		if ( _cancelled() ) {
			$done->();
			return;
		}

		while ( $index < @$tracks ) {
			my $track = $tracks->[ $index++ ];
			my $u     = $urls->{ $track->{id} };

			if ( $u && $u->{freeTrialInfo} ) {
				$log->info("NetEase download: skipped track $track->{id} "
					. '(trial clip only)');
				_job_bump('skipped');
				next;
			}

			unless ( $u && defined $u->{url} && length $u->{url} ) {
				$log->info("NetEase download: skipped track $track->{id} ("
					. ( ( $u && $u->{reason} ) || 'no URL' ) . ')');
				_job_bump('skipped');
				next;
			}

			my $path = File::Spec->catfile( $dir, _filename( $track, $u->{url} ) );

			if ( -e $path && -s $path ) {
				$log->info("NetEase download: already exists, skipped $path");
				_job_bump('skipped');
				next;
			}

			_job_update( current => _track_label($track) );

			_download_file( $u->{url}, $path, 1, sub {
				my $ok = shift;
				_job_bump( $ok ? 'saved' : 'failed' );
				$step->();
			} );
			return;
		}

		$done->();
	};

	$step->();
}

sub _download_file {
	my ( $url, $path, $attempt, $done ) = @_;

	my $tmp = "$path.part";

	unlink $tmp if -e $tmp;

	# saveAs 让 LMS 直接把响应体写入文件，避免把整首歌读进内存。
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			unless ( -e $tmp && -s $tmp ) {
				unlink $tmp if -e $tmp;
				_log_fail_and_retry( $url, $path, $attempt, 'empty response', $done );
				return;
			}

			unless ( rename $tmp, $path ) {
				unlink $tmp if -e $tmp;
				_log_fail_and_retry( $url, $path, $attempt, 'rename failed', $done );
				return;
			}

			$log->info("NetEase download: saved $path");
			$done->(1);
		},
		sub {
			my ( $response, $err ) = @_;

			unlink $tmp if -e $tmp;

			my $reason = ref($err) eq 'HASH'
				? ( $err->{message} || $err->{error} || 'HTTP error' )
				: ( $err || 'HTTP error' );

			_log_fail_and_retry( $url, $path, $attempt, "$reason", $done );
		},
		{
			saveAs  => $tmp,
			timeout => 300,
			cache   => 0,
		},
	);

	$http->get(
		$url,
		'User-Agent' => $UA,
		'Referer'    => 'https://music.163.com/',
	);
}

sub _log_fail_and_retry {
	my ( $url, $path, $attempt, $reason, $done ) = @_;

	# 不打印带签名的播放 URL。
	if ( $attempt < 3 ) {
		$log->warn("NetEase download: attempt $attempt failed for $path ($reason), retrying");
		Slim::Utils::Timers::setTimer( undef, time() + 5 * $attempt, sub {
			_download_file( $url, $path, $attempt + 1, $done );
		} );
		return;
	}

	$log->error("NetEase download: giving up on $path after $attempt attempts ($reason)");
	_job_error("download failed ($reason): $path");
	$done->(0);
}

sub _playlist_dir {
	my $name = shift;

	my $base = effectiveDir();

	return undef unless defined $base;

	$name = 'untitled' unless defined $name && length $name;

	my $dir = File::Spec->catdir( $base, _sanitize($name) );

	unless ( -d $dir ) {
		eval { mkpath($dir) };
		if ($@) {
			$log->error("NetEase download: cannot create $dir: $@");
			return undef;
		}
	}

	return $dir;
}

sub _track_label {
	my $track = shift;

	my @artists;
	for my $a ( @{ $track->{artist} || [] } ) {
		next unless ref($a) eq 'HASH';
		push @artists, $a->{name} if defined $a->{name} && length $a->{name};
	}

	my $artist = join( ', ', @artists );
	my $title  = $track->{name} || "track-$track->{id}";

	return ( $artist ? "$artist - " : '' ) . $title;
}

sub _filename {
	my ( $track, $url ) = @_;

	my $id  = $track->{id};
	my $ext = _extension($url);

	my $name = _track_label($track) . " [$id].$ext";

	return _sanitize($name);
}

sub _extension {
	my $url = shift;

	my ($ext) = $url =~ m{\.([A-Za-z0-9]{2,5})(?:[?#]|$)};

	$ext = lc( $ext || '' );

	return $ext if $ext =~ /^(?:mp3|flac|m4a|aac|wav|ogg|opus)$/;

	return 'mp3';
}

sub _sanitize {
	my $name = shift;

	$name = '' unless defined $name;

	$name =~ s{[\x00-\x1f\x7f]}{}g;
	$name =~ s{[\\/:*?"<>|]}{_}g;
	$name =~ s{\s+}{ }g;
	$name =~ s{^\s+|\s+$}{}g;

	$name = substr( $name, 0, 120 ) if length($name) > 120;

	return length($name) ? $name : 'untitled';
}

1;

__END__

=head1 NAME

Plugins::NetEase::Downloader - 网易云歌曲下载器

=head1 DESCRIPTION

把歌单/单曲下载到本地目录。下载任务串行执行，已存在的文件跳过，失败
最多重试 3 次。每个任务的状态、进度和错误信息通过 C<queueStatus>
暴露给监控页。日志中只记录本地路径，不记录带签名的播放 URL。

=cut
