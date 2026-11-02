package Plugins::NetEase::ProtocolHandler;

use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.netease');
my $prefs = preferences('plugin.netease');
my $cache = Slim::Utils::Cache->new;

# 网易云 CDN 对 FLAC 也返回 Content-Type: audio/mpeg，LMS 的远程扫描器
# 会据此把曲目判定成 mp3，播放器随后按 MP3 解码 FLAC 数据而卡住。
# 这里按音频地址的后缀还原真实类型（LMS 内部 FLAC 的类型名是 flc）。
my %EXT_TO_TYPE = (
	flac => 'flc',
	mp3  => 'mp3',
	m4a  => 'mp4',
	mp4  => 'mp4',
	aac  => 'aac',
	ogg  => 'ogg',
	opus => 'ops',
	wav  => 'wav',
);

sub _type_from_url {
	my $url = shift;

	return undef unless defined $url && length $url;

	my $path = $url;
	$path =~ s/[?#].*//;

	my ($ext) = $path =~ m{\.([a-z0-9]{2,4})$}i;

	return $ext ? $EXT_TO_TYPE{ lc $ext } : undef;
}

Slim::Player::ProtocolHandlers->registerHandler( 'netease', __PACKAGE__ );

sub init {
	return 1;
}

sub new {
	my ( $class, $args ) = @_;

	if ( $args->{song} ) {
		$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	}

	return $class->SUPER::new($args);
}

sub scanUrl {
	my ( $class, $url, $args ) = @_;

	my ($id) = $url =~ m{^netease://track/(\d+)};

	my $song = $args->{song};
	my $cb   = $args->{cb};

	unless ($id) {
		$log->warn('Invalid NetEase track URL');
		$cb->(undef);
		return;
	}

	require Plugins::NetEase::API;

	# 播放前的"预检测"直接复用 LMS 对音频地址的探测：探测不过就换档重试，
	# 而不是像以前那样立刻放弃（那会表现为卡一下后自动跳过）。
	my @levels = Plugins::NetEase::API->qualityChain( $prefs->get('quality') );
	my $level  = 0;

	my $fail;
	my $try;

	$try = sub {
		my $cached = $cache->get("netease_url_$id");

		if ($cached) {
			$class->_attempt( $url, $cached, $args, $song, $cb, $fail );
			return;
		}

		Plugins::NetEase::API->getSongUrl(
			$id,
			sub {
				my $u = shift;

				unless ( $u && defined $u->{url} && length $u->{url} ) {
					$log->warn("No stream URL for NetEase track $id (reason: "
						. ( ( $u && $u->{reason} ) || 'unknown' ) . ')');
					$fail->('no url');
					return;
				}

				# 播放地址带有效期，只做短时间缓存。
				$cache->set( "netease_url_$id", $u->{url}, 300 );

				$class->_attempt( $url, $u->{url}, $args, $song, $cb, $fail );
			},
			sub {
				my $err = shift || 'unknown error';
				$log->warn("Failed to resolve NetEase track $id: $err");
				$fail->('resolve error');
			},
			$levels[$level],
		);
	};

	$fail = sub {
		my $why = shift || 'unknown';

		# 缓存的地址可能已过期或失效，重试前先丢掉，强制重新解析。
		$cache->remove("netease_url_$id");

		$level++;

		if ( $level > $#levels ) {
			$log->warn("Giving up on NetEase track $id after trying "
				. join( '/', @levels ) . " ($why)");
			$cb->(undef);
			return;
		}

		$log->info("Retrying NetEase track $id at '$levels[$level]' ($why)");
		$try->();
	};

	$try->();
}

sub _attempt {
	my ( $class, $url, $realUrl, $args, $song, $cb, $fail ) = @_;

	my $settled = 0;

	$args->{cb} = sub {
		my $track = shift;

		return if $settled;

		if ( !$track ) {
			$settled = 1;
			$fail->('stream rejected');
			return;
		}

		$settled = 1;

		# 扫描器只看响应头，FLAC 会被记成 mp3；按真实地址后缀纠正，
		# 让 LMS 用正确的格式告诉播放器（也影响是否直接流式传输）。
		my $type = _type_from_url($realUrl);

		if ( $type
			&& $track->can('content_type')
			&& ( $track->content_type || '' ) ne $type )
		{
			Slim::Schema->clearContentTypeCache($realUrl);
			Slim::Music::Info::setContentType( $realUrl, $type );
			$track->content_type($type);
		}

		if ($song) {
			$song->streamUrl( $track->url );
			$track->url($url);
		}

		$cb->( $track, @_ );
	};

	$class->SUPER::scanUrl( $realUrl, $args );
}

# LMS 自己连接音频地址时会按响应头再次判定类型，这里同样按后缀纠正，
# 避免 FLAC 的 audio/mpeg 响应头覆盖掉扫描阶段的判断。
sub parseDirectHeaders {
	my ( $self, $client, $url, @headers ) = @_;

	my @parsed = $self->SUPER::parseDirectHeaders( $client, $url, @headers );

	my $real = ref($url) ? $url->url : $url;

	if ( my $type = _type_from_url($real) ) {
		$parsed[4] = $type;
	}

	return @parsed;
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $url =~ m{^netease://track/(\d+)};

	return {} unless $id;

	my $meta = $cache->get("netease_meta_$id") || {};

	my %out;
	for my $key ( qw(title artist album cover duration) ) {
		$out{$key} = $meta->{$key} if defined $meta->{$key} && length $meta->{$key};
	}

	return \%out;
}

sub shouldCacheImage {
	return 1;
}

1;

__END__

=head1 NAME

Plugins::NetEase::ProtocolHandler - 网易云在线播放协议处理器

=head1 DESCRIPTION

注册 C<netease://> 协议。播放前通过 Plugins::NetEase::API 解析真实音频
URL，再交给 LMS 的 HTTPS 处理器，因此重定向、Range/seek 等行为复用 LMS
核心实现。

=cut
