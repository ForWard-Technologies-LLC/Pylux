// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common.ext

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import io.reactivex.BackpressureStrategy
import io.reactivex.Observable
import io.reactivex.Single
import io.reactivex.disposables.Disposable
import org.reactivestreams.Publisher
import org.reactivestreams.Subscriber
import org.reactivestreams.Subscription

fun <T> Publisher<T>.toLiveData(): LiveData<T> {
	val liveData = MutableLiveData<T>()
	this.subscribe(object : Subscriber<T> {
		override fun onSubscribe(s: Subscription) {
			s.request(Long.MAX_VALUE)
		}
		override fun onNext(t: T) {
			liveData.postValue(t)
		}
		override fun onError(t: Throwable) {}
		override fun onComplete() {}
	})
	return liveData
}

fun <T> Observable<T>.toLiveData() = this.toFlowable(BackpressureStrategy.LATEST).toLiveData()
fun <T> Single<T>.toLiveData() = this.toFlowable().toLiveData()