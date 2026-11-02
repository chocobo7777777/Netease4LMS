package Plugins::NetEase::Downloads;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.netease');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_NETEASE_DLQ_TITLE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/NetEase/settings/downloads.html');
}

# 监控页不保存任何设置，pref 列表为空。
sub prefs {
	return ($prefs);
}

sub handler {
	my ( $class, $client, $params ) = @_;

	require Plugins::NetEase::Downloader;

	if ( defined $params->{cancelJob} && length $params->{cancelJob} ) {
		Plugins::NetEase::Downloader->cancelJob( $params->{cancelJob} );
	}

	if ( $params->{clearHistory} ) {
		Plugins::NetEase::Downloader->clearHistory;
	}

	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ( $class, $params, $client ) = @_;

	require Plugins::NetEase::Downloader;

	my $status = Plugins::NetEase::Downloader->queueStatus;

	my @jobs = (
		( $status->{current} ? ( $status->{current} ) : () ),
		@{ $status->{pending} },
		@{ $status->{history} },
	);

	for my $job (@jobs) {
		$job->{typeText}   = string( 'PLUGIN_NETEASE_DLQ_TYPE_' . uc( $job->{type} ) );
		$job->{statusText} = string( 'PLUGIN_NETEASE_DLQ_STATUS_' . uc( $job->{status} ) );

		$job->{progress} = $job->{total}
			? "$job->{processed} / $job->{total}"
			: '-';

		$job->{counters} = string(
			'PLUGIN_NETEASE_DLQ_COUNTERS',
			$job->{saved}, $job->{skipped}, $job->{failed},
		);

		$job->{queuedAtFmt}   = _fmt_time( $job->{queuedAt} );
		$job->{startedAtFmt}  = _fmt_time( $job->{startedAt} );
		$job->{finishedAtFmt} = _fmt_time( $job->{finishedAt} );

		$job->{labelText} = length $job->{label} ? $job->{label} : "job $job->{id}";
	}

	$params->{dlCurrent} = $status->{current};
	$params->{dlPending} = $status->{pending};
	$params->{dlHistory} = $status->{history};
	$params->{dlActive}  = ( $status->{current} || @{ $status->{pending} } ) ? 1 : 0;

	# 下载目录诊断：区分“目录不存在”“存在但写不进去”，并显示 LMS 进程身份，
	# 便于和“我用 root 检查是能写的”这类结果对照。
	my $chk = Plugins::NetEase::Downloader->checkDownloadDir;

	if ( $chk->{dir} ) {
		my $token;

		if    ( !$chk->{exists} ) { $token = 'PLUGIN_NETEASE_DLQ_DIR_MISSING' }
		elsif ( !$chk->{writable} ) {
			# 权限位说可写但实际写不进去，基本就是只读挂载 / ACL / root-squash。
			$token = $chk->{bits}
				? 'PLUGIN_NETEASE_DLQ_DIR_NOWRITE_MOUNT'
				: 'PLUGIN_NETEASE_DLQ_DIR_NOWRITE';
		}
		elsif ( $chk->{created} )  { $token = 'PLUGIN_NETEASE_DLQ_DIR_CREATED' }
		else                        { $token = 'PLUGIN_NETEASE_DLQ_DIR_OK' }

		$chk->{statusText} = string($token);

		$chk->{ownerText} = length $chk->{owner}
			? string( 'PLUGIN_NETEASE_DLQ_DIR_OWNER', $chk->{owner}, $chk->{mode} )
			: '';

		$chk->{runAsText} = string(
			'PLUGIN_NETEASE_DLQ_DIR_RUNAS',
			$chk->{user}, $chk->{uid}, $chk->{euid},
		);
	}

	$params->{dlDirCheck} = $chk;
}

sub _fmt_time {
	my $t = shift;

	return '' unless $t;

	my @l = localtime($t);

	return sprintf( '%02d:%02d:%02d', $l[2], $l[1], $l[0] );
}

1;

__END__

=head1 NAME

Plugins::NetEase::Downloads - 下载队列监控页

=head1 DESCRIPTION

只读展示下载队列的当前任务、排队任务与历史任务，支持取消排队/运行中
的任务和清空历史。不保存任何设置项。

=cut
